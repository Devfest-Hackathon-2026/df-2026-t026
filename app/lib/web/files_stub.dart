import 'dart:typed_data';

import '../models.dart';

Future<({Uint8List bytes, String mimeType})> shrinkImage(Uint8List bytes, String mimeType) async =>
    (bytes: bytes, mimeType: mimeType);

Future<List<PickedFile>> takePhoto() async => [];

void Function() onFilesDropped(void Function(List<PickedFile> files) f) => () {};
