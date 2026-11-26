import 'dart:async';

import 'package:web_socket_channel/io.dart';

import 'core_log.dart';

enum SocketStatus { connected, failed, closed }

/// 建立连接的方式，可注入以便测试或自定义。
typedef WebSocketConnector =
    FutureOr<IOWebSocketChannel> Function(
      String url, {
      Duration? connectTimeout,
      Map<String, dynamic>? headers,
    });

class WebScoketUtils {
  SocketStatus status = SocketStatus.closed;

  /// 链接
  final String url;

  /// 备用链接
  final String? backupUrl;

  /// 心跳时间
  final int heartBeatTime;

  /// 接收到信息
  final Function(dynamic)? onMessage;

  /// 连接关闭
  ///
  /// 只在重连次数用尽时才会上报；断线本身由 [onReconnect] 提示一次，
  /// 避免同一次断线给界面连发两条提示。
  final Function(String msg)? onClose;

  /// 尝试重连
  ///
  /// 一次断线流程只会上报一次，重连过程中不会刷屏。
  final Function()? onReconnect;

  /// 准备就绪
  final Function()? onReady;

  /// 心跳
  final Function()? onHeartBeat;

  /// 请求头
  Map<String, dynamic>? headers;

  /// 建立连接的方式，默认走 [IOWebSocketChannel.connect]
  final WebSocketConnector webSocketConnector;

  /// 重连间隔
  final Duration reconnectInterval;

  /// 单次连接超时
  final Duration connectTimeout;

  WebScoketUtils({
    required this.url,
    required this.heartBeatTime,
    this.onMessage,
    this.onClose,
    this.onReconnect,
    this.onReady,
    this.onHeartBeat,
    this.headers,
    this.backupUrl,
    WebSocketConnector? webSocketConnector,
    this.reconnectInterval = const Duration(seconds: 5),
    this.connectTimeout = const Duration(seconds: 10),
    this.maxReconnectTime = 5,
  }) : webSocketConnector = webSocketConnector ?? _connect;

  static IOWebSocketChannel _connect(
    String url, {
    Duration? connectTimeout,
    Map<String, dynamic>? headers,
  }) {
    return IOWebSocketChannel.connect(
      url,
      connectTimeout: connectTimeout,
      headers: headers,
    );
  }

  IOWebSocketChannel? webSocket;
  Timer? heartBeatTimer;

  /// 重连次数
  int reconnectTime = 0;
  Timer? reconnectTimer;

  /// 最大重连次数
  int maxReconnectTime;

  StreamSubscription<dynamic>? streamSubscription;

  /// 世代计数：每次显式 connect() 递增，
  /// 旧连接迟到的 onError/onDone 凭此作废，不会误踢新连接。
  int _generation = 0;

  /// 调用方是否还需要这条连接；close() 之后为 false，彻底停止重连
  bool _active = false;

  /// 是否正有一次连接流程在进行
  bool _connecting = false;

  /// 是否由调用方主动关闭（主动关闭后不再自动重连）
  bool get closedByUser => !_active;

  /// 发起连接。
  ///
  /// [retry] 为 true 时直接从备用地址开始尝试（供内部重试使用）。
  void connect({bool retry = false}) {
    _active = true;
    reconnectTime = 0;
    _generation++;
    _connecting = false;
    _cancelTimersAndTransport();
    status = SocketStatus.closed;
    unawaited(_connectGeneration(_generation, startWithBackup: retry));
  }

  Future<void> _connectGeneration(
    int generation, {
    bool startWithBackup = false,
  }) async {
    if (!_isCurrent(generation) || _connecting) return;
    _connecting = true;
    Object? lastError;
    final urls = <String>[
      if (!startWithBackup) url,
      if (backupUrl != null && backupUrl!.isNotEmpty) backupUrl!,
    ];
    if (urls.isEmpty) urls.add(url);

    try {
      for (final socketUrl in urls) {
        IOWebSocketChannel? candidate;
        try {
          candidate = await webSocketConnector(
            socketUrl,
            connectTimeout: connectTimeout,
            headers: headers,
          );
          if (!_isCurrent(generation)) {
            _discardCandidate(candidate);
            return;
          }
          await candidate.ready;
          if (!_isCurrent(generation)) {
            _discardCandidate(candidate);
            return;
          }
          webSocket = candidate;
          _ready(generation);
          return;
        } catch (error) {
          lastError = error;
          if (candidate != null) {
            if (candidate == webSocket) {
              _disposeTransport();
            } else {
              _discardCandidate(candidate);
            }
          }
          if (!_isCurrent(generation)) return;
        }
      }
    } finally {
      if (generation == _generation) _connecting = false;
    }

    if (_isCurrent(generation)) {
      _handleFailure(
        lastError ?? StateError('WebSocket connection failed'),
        generation: generation,
      );
    }
  }

  bool _isCurrent(int generation) => _active && generation == _generation;

  void _discardCandidate(IOWebSocketChannel candidate) {
    // ready 与 stream 都会报告握手失败；未监听的 stream 还会阻塞 sink.close。
    candidate.stream.listen(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    unawaited(candidate.sink.close().catchError((Object error) {}));
  }

  /// 连接完成。保留此方法以兼容现有调用方。
  void ready() => _ready(_generation);

  void _ready(int generation) {
    if (!_isCurrent(generation) || webSocket == null) return;
    status = SocketStatus.connected;
    _connecting = false;

    streamSubscription = webSocket!.stream.listen(
      receiveMessage,
      onError: (Object error, StackTrace stackTrace) {
        _handleFailure(error, generation: generation);
      },
      onDone: () {
        _handleFailure(StateError('WebSocket closed'), generation: generation);
      },
      cancelOnError: true,
    );

    onReady?.call();
    initHeartBeat();
  }

  void initHeartBeat() {
    heartBeatTimer?.cancel();
    heartBeatTimer = Timer.periodic(Duration(milliseconds: heartBeatTime), (
      timer,
    ) {
      onHeartBeat?.call();
    });
  }

  void receiveMessage(dynamic data) {
    // 接受到一条信息才算重连成功
    reconnectTime = 0;
    // 通信已经恢复，停掉还没触发的重连，
    // 否则它到点后会把刚恢复的正常连接踢掉
    _cancelReconnectTimer();
    onMessage?.call(data);
  }

  void onError(Object error, Object stackTrace) => _handleFailure(error);

  void onDone() => _handleFailure(StateError('WebSocket closed'));

  void _handleFailure(Object error, {int? generation}) {
    if (!_active || (generation != null && generation != _generation)) return;
    status = SocketStatus.failed;
    CoreLog.d("WebSocket 连接出错：$error");
    reconnect();
  }

  void sendMessage(dynamic message) {
    if (status == SocketStatus.connected) {
      webSocket?.sink.add(message);
    }
  }

  /// 主动关闭，并彻底停止自动重连（离开直播间时调用）
  void close() {
    _active = false;
    _generation++;
    status = SocketStatus.closed;
    _connecting = false;
    _cancelTimersAndTransport();
  }

  void _cancelReconnectTimer() {
    reconnectTimer?.cancel();
    reconnectTimer = null;
  }

  void _cancelTimersAndTransport() {
    _cancelReconnectTimer();
    _disposeTransport();
  }

  void _disposeTransport() {
    heartBeatTimer?.cancel();
    heartBeatTimer = null;

    final subscription = streamSubscription;
    streamSubscription = null;
    unawaited(subscription?.cancel());

    final socket = webSocket;
    webSocket = null;
    if (socket != null) {
      unawaited(socket.sink.close().catchError((Object error) {}));
    }
  }

  /// 进入重连流程（已在流程中或已主动关闭则忽略）
  void reconnect() {
    if (!_active) return;
    _disposeTransport();
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (!_active || _connecting || reconnectTimer != null) return;
    if (reconnectTime >= maxReconnectTime) {
      onClose?.call("重连超过最大次数，与服务器断开连接");
      close();
      return;
    }
    // 只在一次断线流程开始时提示一次，避免重连过程中刷屏
    if (reconnectTime == 0) {
      onReconnect?.call();
    }
    reconnectTime++;
    final attempt = reconnectTime;
    // 一次性 Timer 逐次重排：不能用 Timer.periodic，
    // 否则重连里的 connect() 会把定时器取消掉，导致只重连一次。
    reconnectTimer = Timer(reconnectInterval, () {
      reconnectTimer = null;
      if (!_active) return;
      CoreLog.d("WebSocket 正在尝试第 $attempt 次重连：$url");
      unawaited(_connectGeneration(_generation));
    });
  }
}
