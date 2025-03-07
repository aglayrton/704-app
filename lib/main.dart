import 'package:camera/camera.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_application_1/views/photo_view.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:sqflite/sqflite.dart';
import 'package:workmanager/workmanager.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path/path.dart';
import 'dart:io';
import 'dart:async';
import 'dart:typed_data';

// Configuração da API
const String API_URL = 'http://192.168.0.9:8000/api/v1/audio/analyze'; // Substitua pela URL da sua API
const String IMAGE_UPLOAD_URL = 'http://192.168.0.9:8000/api/v1/images/upload'; // URL para upload de imagens

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Inicializa a câmera
  final cameras = await availableCameras();
  final firstCamera = cameras.first;

  Workmanager().initialize(
    callbackDispatcher,
    isInDebugMode: true,
  );
  runApp(MyApp(camera: firstCamera));
}

void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    final Dio dio = Dio();
    final recorder = FlutterSoundRecorder();
    await recorder.openRecorder();
    final directory = await getApplicationDocumentsDirectory();
    final path = '${directory.path}/background_recording_${DateTime.now().millisecondsSinceEpoch}.aac';

    // Configuração para gravação
    await recorder.startRecorder(toFile: path);

    // Configurar um stream para monitorar o arquivo
    final file = File(path);
    Timer.periodic(Duration(seconds: 1), (timer) async {
      if (await file.exists()) {
        try {
          Uint8List audioBytes = await file.readAsBytes();
          // Envia o chunk para a API
          await sendAudioChunk(audioBytes, DateTime.now().toString());
        } catch (e) {
          print('Erro ao ler arquivo de áudio: $e');
        }
      }
    });

    await Future.delayed(Duration(seconds: 10)); // Grava por 10 segundos
    await recorder.stopRecorder();
    await recorder.closeRecorder();

    // Salva o áudio gravado no banco de dados
    final dbHelper = DatabaseHelper();
    await dbHelper.insertRecording(path, DateTime.now().toString());
    return true;
  });
}

// Função para capturar fotos automaticamente
Future<List<String>> _capturePhotosAutomatically(CameraController cameraController) async {
  List<String> photoPaths = [];
  for (int i = 0; i < 3; i++) {
    try {
      final path = '${(await getTemporaryDirectory()).path}/${DateTime.now().millisecondsSinceEpoch}.jpg';
      await cameraController.takePicture().then((XFile file) async {
        await file.saveTo(path);
        photoPaths.add(path);
        print('Foto capturada e salva em: $path');
      });
    } catch (e) {
      print('Erro ao capturar foto: $e');
    }

    await Future.delayed(Duration(milliseconds: 500)); // Pequeno intervalo entre fotos
  }
  return photoPaths;
}

// Função para enviar chunks de áudio para a API
Future<void> sendAudioChunk(Uint8List audioData, String timestamp) async {
  try {
    final Dio dio = Dio();

    // Crie o FormData com o campo "audio_file"
    FormData formData = FormData.fromMap({
      'audio_file': MultipartFile.fromBytes(
        audioData,
        filename: 'audio_$timestamp.mp3', // Nome do arquivo
      ),
      // Adicione outros campos se necessário
      'timestamp': timestamp,
    });

    // Envie a requisição
    final response = await dio.post(
      API_URL, // URL da API
      data: formData,
      options: Options(
        headers: {
          'Content-Type': 'multipart/form-data', // Cabeçalho correto
        },
      ),
    );

    // Verifique a resposta
    if (response.statusCode == 200) {
      print('Chunk de áudio enviado com sucesso: $timestamp');
    } else {
      print('Erro na API: ${response.statusCode} - ${response.data}');
    }
  } catch (e) {
    print('Erro ao enviar chunk de áudio: $e');
  }
}

// Função para enviar as fotos para a API
Future<void> _sendImagesToApi(List<String> imagePaths, String audioTranscriptionId) async {
  try {
    final Dio dio = Dio();

    // Crie o FormData com as imagens
    FormData formData = FormData.fromMap({
      'audio_transcription': audioTranscriptionId,
    });

    // Adicione cada imagem ao FormData
    for (var path in imagePaths) {
      formData.files.add(MapEntry(
        'image_files',
        await MultipartFile.fromFile(path),
      ));
    }

    // Envie a requisição
    final response = await dio.post(
      IMAGE_UPLOAD_URL,
      data: formData,
      options: Options(
        headers: {
          'Content-Type': 'multipart/form-data',
        },
      ),
    );

    // Verifique a resposta
    if (response.statusCode == 200|| response.statusCode == 201 ) {
      print('Fotos enviadas com sucesso para a API');
    } else {
      print('Erro na API: ${response.statusCode} - ${response.data}');
    }
  } catch (e) {
    print('Erro ao enviar fotos: $e');
  }
}

class MyApp extends StatelessWidget {
  final CameraDescription camera;

  const MyApp({super.key, required this.camera});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: AudioRecorderApp(camera: camera),
    );
  }
}

class AudioRecorderApp extends StatefulWidget {
  final CameraDescription camera;

  const AudioRecorderApp({super.key, required this.camera});

  @override
  _AudioRecorderAppState createState() => _AudioRecorderAppState();
}

class _AudioRecorderAppState extends State<AudioRecorderApp> {
  final FlutterSoundRecorder _recorder = FlutterSoundRecorder();
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _isRecording = false;
  String _recordingPath = '';
  final DatabaseHelper _dbHelper = DatabaseHelper();
  List<Map<String, dynamic>> _recordings = [];
  Timer? _chunkTimer;
  File? _currentRecordingFile;
  StreamSubscription? _recorderSubscription;
  bool? _isHostile; // Novo estado para armazenar is_hostile
  bool _isLoading = false; // Novo estado para controlar o carregamento
  late CameraController _cameraController;

  @override
  void initState() {
    super.initState();
    _requestPermissions();
    _loadRecordings();
    _initRecorder();
    _initCamera();
  }

  Future<void> _initCamera() async {
    _cameraController = CameraController(
      widget.camera,
      ResolutionPreset.medium,
    );
    await _cameraController.initialize();
  }

  Future<void> _initRecorder() async {
    await _recorder.openRecorder();
    // Configure o recorder para emitir atualizações de dB a cada 10ms
    await _recorder.setSubscriptionDuration(Duration(milliseconds: 100));
  }

  @override
  void dispose() {
    _chunkTimer?.cancel();
    _recorderSubscription?.cancel();
    _recorder.closeRecorder();
    _cameraController.dispose();
    super.dispose();
  }

  Future<void> _requestPermissions() async {
    await Permission.microphone.request();
    await Permission.storage.request();
    await Permission.camera.request();
  }

  Future<void> _startRecording() async {
    final directory = await getApplicationDocumentsDirectory();
    final path = '${directory.path}/recording_${DateTime.now().millisecondsSinceEpoch}.aac';

    // Criar o arquivo para a gravação atual
    _currentRecordingFile = File(path);

    await _recorder.startRecorder(toFile: path);

    // Assinar para receber atualizações sobre a gravação
    _recorderSubscription = _recorder.onProgress?.listen((event) {
      // Este callback é chamado periodicamente durante a gravação
      print('Gravando: ${event.duration} - ${event.decibels} dB');
    });

    setState(() {
      _isRecording = true;
      _recordingPath = path;
    });

    _chunkTimer = Timer.periodic(Duration(seconds: 10), (timer) async {
      await _sendCurrentAudioChunk();
    });
  }

  Future<void> _sendCurrentAudioChunk() async {
    if (_currentRecordingFile != null && await _currentRecordingFile!.exists()) {
      try {
        Uint8List audioBytes = await _currentRecordingFile!.readAsBytes();
        await _sendAudioToApi(audioBytes, DateTime.now().toString());
      } catch (e) {
        print('Erro ao ler ou enviar áudio: $e');
      }
    }
  }

  Future<void> _sendAudioToApi(Uint8List audioData, String timestamp) async {
    setState(() {
      _isLoading = true;
    });
        // Se o áudio for hostil, captura fotos automaticamente
    try {
      final Dio dio = Dio();
      FormData formData = FormData.fromMap({
        'audio_file': MultipartFile.fromBytes(audioData, filename: 'audio_$timestamp.mp3'),
        'timestamp': timestamp,
      });

      final response = await dio.post(API_URL, data: formData);

      if (response.statusCode == 200 || response.statusCode == 201) {
  final responseData = response.data;

  if (responseData.containsKey('is_hostile')) {
    final String id = responseData['id'];
    final bool isHostile = responseData['is_hostile'] == true; // Garante conversão segura

    setState(() {
      _isHostile = isHostile;
      _isLoading = false;
    });

    if (_isHostile == true) {
      List<String> photoPaths = await _capturePhotosAutomatically(_cameraController);
      await _sendImagesToApi(photoPaths, id); // Envia as fotos para a API
    }

    await _dbHelper.updateRecordingId(_recordingPath, id);
  } else {
    print('Campo is_hostile não encontrado na resposta da API.');
  }
} else {
  print('Erro na API: ${response.statusCode} - ${response.data}');
}

    } catch (e) {
      print('Erro ao enviar áudio: $e');
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _stopRecording() async {
    _chunkTimer?.cancel();
    _chunkTimer = null;
    _recorderSubscription?.cancel();

    await _recorder.stopRecorder();

    // Envia o último chunk
    await _sendCurrentAudioChunk();

    setState(() {
      _isRecording = false;
    });

    // Salva o áudio gravado no banco de dados
    await _dbHelper.insertRecording(_recordingPath, DateTime.now().toString());
    await _loadRecordings();
  }

  Future<void> _cancelRecording() async {
    _chunkTimer?.cancel();
    _chunkTimer = null;
    _recorderSubscription?.cancel();

    await _recorder.stopRecorder();

    // Exclui o arquivo de gravação atual
    if (_currentRecordingFile != null && await _currentRecordingFile!.exists()) {
      await _currentRecordingFile!.delete();
    }

    setState(() {
      _isRecording = false;
      _recordingPath = '';
      _isHostile = null; // Reseta o estado de hostilidade
    });
  }

  Future<void> _playRecording(String path) async {
    if (path.isNotEmpty) {
      await _audioPlayer.play(DeviceFileSource(path));
    }
  }

  Future<void> _loadRecordings() async {
    final recordings = await _dbHelper.getRecordings();
    setState(() {
      _recordings = recordings;
    });
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('App 704'),  actions: [
          IconButton(
            icon: Icon(Icons.photo_library),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => PhotoViewer(), // Abre a tela de visualização de fotos
                ),
              );
            },
          ),
        ],),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              itemCount: _recordings.length,
              itemBuilder: (context, index) {
                final recording = _recordings[index];
                return ListTile(
                  title: Text('Gravação ${index + 1}'),
                  subtitle: Text(recording['date']),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: Icon(Icons.play_arrow),
                        onPressed: () => _playRecording(recording['path']),
                      ),
                      IconButton(
                        icon: Icon(Icons.cloud_upload),
                        onPressed: () async {
                          File audioFile = File(recording['path']);
                          if (await audioFile.exists()) {
                            Uint8List audioBytes = await audioFile.readAsBytes();
                            await _sendAudioToApi(audioBytes, recording['date']);
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Áudio enviado para API')),
                            );
                          }
                        },
                      ),
                    ],
                  ),
                  onTap: () => _playRecording(recording['path']),
                );
              },
            ),
          ),
          if (_isRecording)
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Text(
                'Enviando áudio em tempo real...',
                style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
              ),
            ),
          if (_isHostile != null)
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Text(
                'O áudio é hostil? ${_isHostile! ? "Sim" : "Não"}',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: _isHostile! ? Colors.red : Colors.green,
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                GestureDetector(
                  onTap: () {
                    if (_isRecording) {
                      _stopRecording();
                    } else {
                      _startRecording();
                      
                    }
                  },
                  child: Container(
                    width: 70,
                    height: 70,
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.black),
                      shape: BoxShape.circle,
                    ),
                    child: Center(
                      child: Text(
                        !_isRecording ? 'INICIAR' : 'INICIADO',
                        style: TextStyle(fontWeight: FontWeight.w500),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class DatabaseHelper {
  static final DatabaseHelper _instance = DatabaseHelper._internal();
  factory DatabaseHelper() => _instance;
  static Database? _database;

  DatabaseHelper._internal();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final directory = await getApplicationDocumentsDirectory();
    final path = join(directory.path, 'recordings.db');
    return await openDatabase(
      path,
      version: 1,
      onCreate: _onCreate,
    );
  }

   Future<void> updateRecordingId(String recordingPath, String id) async {
    try {
      await _database?.update(
        'recordings',
        {'id': id},
        where: 'path = ?',
        whereArgs: [recordingPath],
      );
      print('ID atualizado com sucesso para o caminho: $recordingPath');
    } catch (e) {
      print('Erro ao atualizar o ID: $e');
    }
   }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute(
      'CREATE TABLE recordings(id INTEGER PRIMARY KEY, path TEXT, date TEXT)',
    );
  }

  Future<void> insertRecording(String path, String date) async {
    final db = await database;
    await db.insert(
      'recordings',
      {'path': path, 'date': date},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Map<String, dynamic>>> getRecordings() async {
    final db = await database;
    return await db.query('recordings', orderBy: 'date DESC');
  }
}