import 'dart:async';

import 'package:web_socket_channel/io.dart';

import 'core_log.dart';

enum SocketStatus { connected, failed, closed }

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
  final Function(String msg)? onClose;

  /// 尝试重连
  final Function()? onReconnect;

  /// 准备就绪
  final Function()? onReady;

  /// 心跳
  final Function()? onHeartBeat;

  /// 请求头
  Map<String, dynamic>? headers;
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
    this.maxReconnectTime = 5,
    this.reconnectInterval = const Duration(seconds: 5),
  });
  IOWebSocketChannel? webSocket;
  Timer? heartBeatTimer;

  /// 重连次数
  int reconnectTime = 0;
  Timer? reconnectTimer;

  /// 最大重连次数
  final int maxReconnectTime;

  /// 重连间隔
  final Duration reconnectInterval;

  /// 是否由调用方主动关闭（主动关闭后不再自动重连）
  bool closedByUser = false;

  StreamSubscription<dynamic>? streamSubscription;

  void connect({bool retry = false}) async {
    if (retry && closedByUser) {
      // 内部备用链接重试期间被 stop() 主动关闭了
      return;
    }
    if (!retry) {
      // 外部主动发起连接：允许同一个实例被重新启用，并取消待执行的重连
      closedByUser = false;
      _cancelReconnectTimer();
    }
    // 这里只清理旧的连接、订阅和心跳，不要碰重连定时器。
    // 否则重连定时器在第一次触发 connect() 时会把自己取消掉，
    // 导致一次断线只会重连一次，之后永久失联。
    _closeSocket();
    try {
      var wsurl = url;
      if (backupUrl != null && backupUrl!.isNotEmpty && retry) {
        wsurl = backupUrl!;
      }
      webSocket = IOWebSocketChannel.connect(
        wsurl,
        connectTimeout: Duration(seconds: 10),
        headers: headers,
      );

      await webSocket?.ready;
      // 等待连接期间被 stop() 主动关闭了，不再继续
      if (closedByUser) {
        return;
      }
      ready();
    } catch (e) {
      if (!retry) {
        connect(retry: true);
        return;
      }
      onError(e, e);
    }
  }

  /// 连接完成
  void ready() {
    status = SocketStatus.connected;

    streamSubscription = webSocket?.stream.listen(
      (data) => receiveMessage(data),
      onError: (e, s) => onError(e, s),
      onDone: onDone,
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
    //接受到一条信息才算重连成功
    reconnectTime = 0;
    // 通信已经恢复，停掉重连定时器，
    // 否则它还会继续重连，把刚恢复的正常连接踢掉
    _cancelReconnectTimer();
    onMessage?.call(data);
  }

  void onError(e, s) {
    status = SocketStatus.failed;
    CoreLog.d("WebSocket 连接出错：$e");
    // 这里不直接上报 onClose：断线提示统一由 reconnect() 的 onReconnect 发出，
    // 只有重连次数用尽才会上报 onClose，避免同一次断线提示两遍。
    // 流层错误同样要进入重连流程，
    // 原先只上报错误不重连，断线后再也连不上
    reconnect();
  }

  void onDone() {
    if (closedByUser || status == SocketStatus.closed) {
      return;
    }
    reconnect();
  }

  void sendMessage(dynamic message) {
    if (status == SocketStatus.connected) {
      webSocket?.sink.add(message);
    }
  }

  /// 关闭当前连接，但不终止重连流程（供 connect() 内部重建连接使用）
  void _closeSocket() {
    status = SocketStatus.closed;

    streamSubscription?.cancel();
    streamSubscription = null;

    webSocket?.sink.close();
    webSocket = null;

    heartBeatTimer?.cancel();
    heartBeatTimer = null;
  }

  void _cancelReconnectTimer() {
    reconnectTimer?.cancel();
    reconnectTimer = null;
  }

  /// 关闭连接并停止自动重连（离开直播间时调用）
  void close() {
    closedByUser = true;
    _cancelReconnectTimer();
    _closeSocket();
  }

  void reconnect() {
    if (closedByUser) {
      return;
    }
    status = SocketStatus.closed;
    // 已经在重连流程中
    if (reconnectTimer != null) {
      return;
    }
    if (reconnectTime >= maxReconnectTime) {
      onClose?.call("重连超过最大次数，与服务器断开连接");
      close();
      return;
    }
    // 只在一次断线流程开始时提示一次，避免重连过程中刷屏
    if (reconnectTime == 0) {
      onReconnect?.call();
    }
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    reconnectTimer = Timer(reconnectInterval, () {
      reconnectTimer = null;
      if (closedByUser) {
        return;
      }
      if (reconnectTime >= maxReconnectTime) {
        onClose?.call("重连超过最大次数，与服务器断开连接");
        close();
        return;
      }
      reconnectTime++;
      CoreLog.d("WebSocket 正在尝试第 $reconnectTime 次重连：$url");
      connect();
    });
  }
}
