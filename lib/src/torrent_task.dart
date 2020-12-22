import 'dart:async';
import 'dart:developer';
import 'dart:io';
import 'dart:typed_data';

import 'package:torrent_model/torrent_model.dart';
import 'package:torrent_tracker/torrent_tracker.dart';

import 'file/download_file_manager.dart';
import 'file/state_file.dart';
import 'peer/peer.dart';
import 'peer/tcp_peer.dart';
import 'piece/base_piece_selector.dart';
import 'piece/piece_manager.dart';
import 'peer/peers_manager.dart';
import 'utils.dart';

const MAX_PEERS = 50;
const MAX_IN_PEERS = 10;

abstract class TorrentTask {
  factory TorrentTask.newTask(Torrent metaInfo, String savePath) {
    return _TorrentTask(metaInfo, savePath);
  }
  Future<double> get downloadSpeed;

  double get uploadSpeed;

  /// Downloaded total bytes length
  int get downloaded;

  Future start();

  Future stop();

  bool get isPaused;

  void pause();

  void resume();

  // Future deleteTask();

  // Future deleteTaskAndFiles();

  bool onTaskComplete(void Function() handler);

  bool offTaskComplete(void Function() handler);

  bool onFileComplete(void Function(String filepath) handler);

  bool offFileComplete(void Function(String filepath) handler);

  bool onStop(void Function() handler);

  bool offStop(void Function() handler);

  bool onPause(void Function() handler);

  bool offPause(void Function() handler);

  bool onResume(void Function() handler);

  bool offResume(void Function() handler);

  @Deprecated('This method is just for debug')
  void addPeer(Uri host, Uri peer);

  @Deprecated('This property is just for debug')
  TorrentAnnounceTracker get tracker;
}

class _TorrentTask implements TorrentTask, AnnounceOptionsProvider {
  final Set<void Function()> _taskCompleteHandlers = {};

  final Set<void Function(String filePath)> _fileCompleteHandlers = {};

  final Set<void Function()> _stopHandlers = {};

  final Set<void Function()> _resumeHandlers = {};

  final Set<void Function()> _pauseHandlers = {};

  TorrentAnnounceTracker _tracker;

  bool _trackerRunning = false;

  StateFile _stateFile;

  PieceManager _pieceManager;

  DownloadFileManager _fileManager;

  PeersManager _peersManager;

  final Torrent _metaInfo;

  final String _savePath;

  final Set<String> _peerIds = {};

  String _peerId;

  ServerSocket _serverSocket;

  Uint8List _infoHashBuffer;

  int _startTime = -1;

  int _startDownloaded = 0;

  int _startUploaded = 0;

  final Set<String> _cominIp = {};

  bool _paused = false;

  _TorrentTask(this._metaInfo, this._savePath) {
    _peerId = generatePeerId();
    _infoHashBuffer = _metaInfo.infoHashBuffer;
  }

  @override
  Future<double> get downloadSpeed async {
    if (_startTime == null || _startTime <= 0) return 0.0;
    var passed = DateTime.now().millisecondsSinceEpoch - _startTime;
    return (_stateFile.downloaded - _startDownloaded) / passed;
  }

  @override
  double get uploadSpeed {
    if (_startTime == null || _startTime <= 0) return 0.0;
    var passed = DateTime.now().millisecondsSinceEpoch - _startTime;
    return (_stateFile.uploaded - _startUploaded) / passed;
  }

  Future<PeersManager> init(Torrent model, String savePath) async {
    _tracker ??=
        TorrentAnnounceTracker(model.announces.toList(), _infoHashBuffer, this);
    if (_stateFile == null) {
      _stateFile = await StateFile.getStateFile(savePath, model);
      _startDownloaded = _stateFile.downloaded;
      _startUploaded = _stateFile.uploaded;
    }
    _pieceManager ??= PieceManager.createPieceManager(
        BasePieceSelector(), model, _stateFile.bitfield);
    _fileManager ??= await DownloadFileManager.createFileManager(
        model, savePath, _stateFile);
    _peersManager ??=
        PeersManager(_pieceManager, _pieceManager, _fileManager, model);
    return _peersManager;
  }

  @override
  void addPeer(Uri host, Uri peer) {
    _tracker?.addPeer(host, peer, _metaInfo.infoHash);
  }

  void _whenTaskDownloadComplete() async {
    var results = await _tracker.complete();
    var peers = <Peer>{};
    peers.addAll(_peersManager.interestedPeers);
    peers.addAll(_peersManager.notInterestedPeers);
    peers.addAll(_peersManager.noResponsePeers);

    peers.forEach((peer) {
      if (peer.isSeeder) {
        peer.dispose('Download complete,disconnect seeder: ${peer.address}');
      }
    });
    _fireTaskComplete();
  }

  void _whenFileDownloadComplete(String filePath) {
    _fireFileComplete(filePath);
  }

  void _whenTrackerOverOneturn(int totalTrackers) {
    _trackerRunning = false;
    _peerIds.clear();
  }

  void _whenNoActivePeers() {
    if (_fileManager != null && _fileManager.isAllComplete) return;
    if (!_trackerRunning) {
      _trackerRunning = true;
      try {
        _tracker?.restart();
      } finally {}
    }
  }

  void _hookOutPeer(Tracker source, PeerEvent event) {
    var ps = event.peers;
    var piecesNum = _metaInfo.pieces.length;
    if (ps != null && ps.isNotEmpty) {
      ps.forEach((url) {
        var id = 'Out:${url.host}:${url.port}';
        if (_peerIds.contains(id)) return;
        _peerIds.add(id);
        var p = TCPPeer(id, _peerId, url, _infoHashBuffer, piecesNum);
        _connectPeer(p);
      });
    }
  }

  void _connectPeer(Peer p) {
    if (p == null) return;
    p.onDispose((source, [reason]) {
      var peer = source as Peer;
      var host = peer.address.host;
      _cominIp.remove(host);
    });
    _peersManager.hookPeer(p);
  }

  void _hookInPeer(Socket socket) {
    var id = 'In:${socket.address.host}:${socket.port}';
    if (_cominIp.length >= MAX_IN_PEERS) {
      socket.close();
      return;
    }
    if (_cominIp.add(socket.address.host)) {
      log('New come in peer : $id', name: runtimeType.toString());
      var piecesNum = _metaInfo.pieces.length;
      var p = TCPPeer(
          id,
          _peerId,
          Uri(host: socket.address.host, port: socket.port),
          _infoHashBuffer,
          piecesNum,
          socket);
      _connectPeer(p);
    } else {
      socket.close();
    }
  }

  @override
  void pause() {
    if (_paused) return;
    _paused = true;
    _peersManager?.pause();
    _fireTaskPaused();
  }

  @override
  bool get isPaused => _paused;

  @override
  void resume() {
    if (isPaused) {
      _paused = false;
      _peersManager?.resume();
      _fireTaskResume();
    }
  }

  @override
  Future start() async {
    _startTime = DateTime.now().millisecondsSinceEpoch;
    // 进入的peer：
    _serverSocket ??= await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    await init(_metaInfo, _savePath);
    _serverSocket.listen(_hookInPeer);
    var map = {};
    map['name'] = _metaInfo.name;
    map['tcp_socket'] = _serverSocket.port;
    map['comoplete_pieces'] = List.from(_stateFile.bitfield.completedPieces);
    map['total_pieces_num'] = _stateFile.bitfield.piecesNum;
    map['downloaded'] = _stateFile.downloaded;
    map['uploaded'] = _stateFile.uploaded;
    map['total_length'] = _metaInfo.length;
    // 主动访问的peer:
    _tracker.onPeerEvent(_hookOutPeer);
    _tracker.onAllAnnounceOver(_whenTrackerOverOneturn);
    _peersManager.onAllComplete(_whenTaskDownloadComplete);
    _peersManager.onNoActivePeerEvent(_whenNoActivePeers);
    _fileManager.onFileComplete(_whenFileDownloadComplete);

    if (_fileManager.isAllComplete) {
      _tracker.complete().catchError((e) async {
        log('Try to complete tracker error :',
            error: e, name: runtimeType.toString());
        await dispose();
      });
    } else {
      _trackerRunning = true;
      _tracker.start().catchError((e) async {
        log('Try to complete tracker error :',
            error: e, name: runtimeType.toString());
        await dispose();
      });
    }
    return map;
  }

  @override
  Future stop([bool force = false]) async {
    await _tracker?.stop(force);
    var tempHandler = Set<Function>.from(_stopHandlers);
    await dispose();
    tempHandler.forEach((element) {
      Timer.run(() => element());
    });
    tempHandler.clear();
    tempHandler = null;
  }

  Future dispose() async {
    _fileCompleteHandlers.clear();
    _taskCompleteHandlers.clear();
    _pauseHandlers.clear();
    _resumeHandlers.clear();
    _stopHandlers.clear();
    _tracker?.offPeerEvent(_hookOutPeer);
    _tracker?.offAllAnnounceOver(_whenTrackerOverOneturn);
    _peersManager?.offAllComplete(_whenTaskDownloadComplete);
    _fileManager?.offFileComplete(_whenFileDownloadComplete);
    // 这是有顺序的,先停止tracker运行,然后停止监听serversocket以及所有的peer,最后关闭文件系统
    await _tracker?.dispose();
    _tracker = null;
    await _peersManager?.dispose();
    _peersManager = null;
    await _serverSocket?.close();
    _serverSocket = null;
    await _fileManager?.close();
    _fileManager = null;

    _peerIds.clear();

    _startTime = -1;
    _cominIp.clear();
    return;
  }

  @override
  Future<Map<String, dynamic>> getOptions(Uri uri, String infoHash) {
    var map = {
      'downloaded': _stateFile?.downloaded,
      'uploaded': _stateFile?.uploaded,
      'left': _metaInfo.length - _stateFile.downloaded,
      'numwant': 50,
      'compact': 1,
      'peerId': _peerId,
      'port': _serverSocket?.port
    };
    return Future.value(map);
  }

  @override
  TorrentAnnounceTracker get tracker => _tracker;

  @override
  bool offFileComplete(void Function(String filepath) handler) {
    return _fileCompleteHandlers.remove(handler);
  }

  void _fireFileComplete(String filepath) {
    _fileCompleteHandlers.forEach((handler) {
      Timer.run(() => handler(filepath));
    });
  }

  @override
  bool offPause(void Function() handler) {
    return _pauseHandlers.remove(handler);
  }

  @override
  bool offResume(void Function() handler) {
    return _resumeHandlers.remove(handler);
  }

  @override
  bool offStop(void Function() handler) {
    return _stopHandlers.remove(handler);
  }

  @override
  bool offTaskComplete(void Function() handler) {
    return _taskCompleteHandlers.remove(handler);
  }

  @override
  bool onFileComplete(void Function(String filepath) handler) {
    return _fileCompleteHandlers.add(handler);
  }

  @override
  bool onPause(void Function() handler) {
    return _pauseHandlers.add(handler);
  }

  @override
  bool onResume(void Function() handler) {
    return _resumeHandlers.add(handler);
  }

  @override
  bool onStop(void Function() handler) {
    return _stopHandlers.add(handler);
  }

  @override
  bool onTaskComplete(void Function() handler) {
    return _taskCompleteHandlers.add(handler);
  }

  void _fireTaskComplete() {
    _taskCompleteHandlers.forEach((element) {
      Timer.run(() => element());
    });
  }

  void _fireTaskStop() {
    _stopHandlers.forEach((element) {
      Timer.run(() => element());
    });
  }

  @override
  int get downloaded => _fileManager?.downloaded;

  void _fireTaskPaused() {
    _pauseHandlers.forEach((element) {
      Timer.run(() => element());
    });
  }

  void _fireTaskResume() {
    _resumeHandlers.forEach((element) {
      Timer.run(() => element());
    });
  }
}
