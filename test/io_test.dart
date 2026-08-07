import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/io.dart';

void main() {
  group('writeFileAtomically', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('venera_io_test');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('writes content and leaves no temp file behind', () async {
      final file = File('${tempDir.path}/data.json');

      await writeFileAtomically(file, '{"a":1}');

      expect(await file.readAsString(), '{"a":1}');
      expect(File('${file.path}.tmp').existsSync(), isFalse);
    });

    test('atomically replaces an existing file', () async {
      final file = File('${tempDir.path}/data.json');
      await file.writeAsString('old');

      await writeFileAtomically(file, '{"b":2}');

      expect(await file.readAsString(), '{"b":2}');
      expect(File('${file.path}.tmp').existsSync(), isFalse);
    });
  });
}