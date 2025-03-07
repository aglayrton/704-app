import 'package:flutter/material.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

class PhotoViewer extends StatefulWidget {
  const PhotoViewer({super.key});

  @override
  _PhotoViewerState createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<PhotoViewer> {
  List<File> _photos = [];

  @override
  void initState() {
    super.initState();
    _loadPhotos();
  }

  Future<void> _loadPhotos() async {
    final directory = await getTemporaryDirectory(); // Acessa o diretório temporário
    final files = directory.listSync().where((file) => file.path.endsWith('.jpg')).toList(); // Filtra apenas arquivos .jpg
    setState(() {
      _photos = files.map((file) => File(file.path)).toList(); // Converte para uma lista de File
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Fotos Capturadas'),
      ),
      body: _photos.isEmpty
          ? Center(child: Text('Nenhuma foto capturada.')) // Mensagem se não houver fotos
          : ListView.builder(
              itemCount: _photos.length,
              itemBuilder: (context, index) {
                return ListTile(
                  leading: Image.file(_photos[index], width: 50, height: 50), // Exibe uma miniatura da foto
                  title: Text('Foto ${index + 1}'),
                  subtitle: Text(_photos[index].path), // Mostra o caminho da foto
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => FullScreenPhoto(photo: _photos[index]), // Abre a foto em tela cheia
                      ),
                    );
                  },
                );
              },
            ),
    );
  }
}

class FullScreenPhoto extends StatelessWidget {
  final File photo;

  const FullScreenPhoto({Key? key, required this.photo}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Foto Completa'),
      ),
      body: Center(
        child: Image.file(photo), // Exibe a foto em tela cheia
      ),
    );
  }
}