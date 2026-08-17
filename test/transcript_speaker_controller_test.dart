import 'dart:io';

import 'package:anker_recorder/state/recorder_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'speaker aliases render by path and file id and reset on replacement',
    () async {
      const path = '/tmp/1783917051.wav';
      const raw = '说话人 1：你好\n说话人 2：再见';
      final controller = RecorderController(loadPersistedState: false)
        ..transcriptsByPath[path] = raw
        ..transcriptsByFileId[1783917051] = raw;
      addTearDown(controller.dispose);

      await controller.renameTranscriptSpeaker(path, '1', '张三：');

      expect(controller.transcriptForPath(path), '张三：你好\n说话人 2：再见');
      expect(controller.transcriptForFileId(1783917051), '张三：你好\n说话人 2：再见');
      expect(
        controller.transcriptSpeakersForPath(path).first.displayLabel,
        '张三',
      );

      controller.rememberTranscript(path, '说话人 1：新的结果');
      expect(controller.speakerAliasesByPath, isEmpty);
      expect(controller.speakerAliasesByFileId, isEmpty);
      expect(controller.transcriptForPath(path), '说话人 1：新的结果');
    },
  );

  test(
    'recording rename and deletion migrate then remove speaker aliases',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'anker-recorder-speaker-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final source = File('${directory.path}/1783917051.wav');
      await source.writeAsBytes([1, 2, 3]);
      final controller = RecorderController(loadPersistedState: false)
        ..exportedPaths = [source.path]
        ..transcriptsByPath[source.path] = '说话人 1：你好'
        ..transcriptsByFileId[1783917051] = '说话人 1：你好'
        ..speakerAliasesByPath[source.path] = {'1': '张三'}
        ..speakerAliasesByFileId[1783917051] = {'1': '张三'};
      addTearDown(controller.dispose);

      final renamed = await controller.renameLocalExport(source.path, '访谈');
      expect(controller.speakerAliasesByPath[source.path], isNull);
      expect(controller.speakerAliasesByPath[renamed], {'1': '张三'});
      expect(controller.transcriptForPath(renamed), '张三：你好');

      final result = await controller.deleteLocalExports([renamed]);
      expect(result.deleted, 1);
      expect(controller.speakerAliasesByPath, isEmpty);
      expect(controller.speakerAliasesByFileId, isEmpty);
    },
  );
}
