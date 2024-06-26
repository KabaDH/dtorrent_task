import 'dart:io';

import 'package:args/args.dart';
import 'package:dtorrent_parser/dtorrent_parser.dart';
import 'package:dtorrent_task/dtorrent_task.dart';
import 'package:logging/logging.dart';

void main(List<String> mainArgs) async {
  var logFile = File('tmp/dtorrent.log');
  var logFileAccess = logFile.openWrite(mode: FileMode.append);
  Logger.root.level = Level.INFO; // defaults to Level.INFO
  Logger.root.onRecord.listen((record) {
    logFileAccess.writeln(
        '[${record.loggerName}] ${record.level.name}: ${record.time}: ${record.message}');
  });
  var parser = ArgParser();
  parser.addOption(
    'task-type',
    help: 'Choose the download type',
    abbr: "t",
    allowed: ['download', 'stream'],
    defaultsTo: 'download',
  );
  parser.addFlag(
    'help',
    help: 'show usage/help',
    abbr: 'h',
    aliases: ['usage'],
    negatable: false,
  );
  showHelp() {
    print(parser.usage);
    exit(0);
  }

  var args = parser.parse(mainArgs);
  if (args['help']) {
    showHelp();
  }

  if (args.rest.length < 2) {
    print('Please provide a .torrent file and a save dir');
    exit(0);
  }
  var filePath = mainArgs[0];

  if (!File(filePath).existsSync()) {
    print('File Can\'t be read');
    exit(0);
  }
  var saveDir = args.rest[1];
  if (!Directory(saveDir).existsSync()) {
    print('dir Can\'t be read');
    exit(0);
  }
  var torrent = await Torrent.parse(filePath);
  TorrentTask task;
  bool stream = false;
  if (args['task-type'] == 'stream') {
    stream = true;
  }
  task = TorrentTask.newTask(torrent, saveDir, stream);

  var listener = task.createListener();
  listener
    ..on<StreamingServerStarted>(
      (event) => print(
          'Streaming started on http://${event.internetAddress.address}:${event.port}'),
    )
    ..on<TaskFileCompleted>(
        (event) => print('${event.file.filePath} file completed'))
    ..on<StateFileUpdated>(
      (event) {
        var progress = '${(task.progress * 100).toStringAsFixed(2)}%';
        var ads =
            ((task.averageDownloadSpeed) * 1000 / 1024).toStringAsFixed(2);
        var aps = ((task.averageUploadSpeed) * 1000 / 1024).toStringAsFixed(2);
        var ds = ((task.currentDownloadSpeed) * 1000 / 1024).toStringAsFixed(2);
        var ps = ((task.uploadSpeed) * 1000 / 1024).toStringAsFixed(2);

        var utpDownloadSpeed =
            ((task.utpDownloadSpeed) * 1000 / 1024).toStringAsFixed(2);
        var utpUploadSpeed =
            ((task.utpUploadSpeed) * 1000 / 1024).toStringAsFixed(2);
        var utpPeerCount = task.utpPeerCount;

        var active = task.connectedPeersNumber;
        var seeders = task.seederNumber;
        var all = task.allPeersNumber;
        print(
            'Progress : $progress , Peers:($active/$seeders/$all)($utpPeerCount) . Download speed : ($utpDownloadSpeed)($ads/$ds)kb/s , upload speed : ($utpUploadSpeed)($aps/$ps)kb/s');
      },
    );

  await task.start();
  if (stream) {
    await task.startStreaming();
  }
}
