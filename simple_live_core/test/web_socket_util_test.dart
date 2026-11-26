import 'dart:async';
import 'dart:io';

import 'package:simple_live_core/src/common/web_socket_util.dart';
import 'package:test/test.dart';

/// 起一个本地 WebSocket 服务，记录被连接次数，并在 accept 后立刻断开，
/// 用来模拟“直播看到一半连接被服务端掐断”的场景。
class _FlakyServer {
  late HttpServer _server;
  int connections = 0;

  /// 为 true 时，连接建立后立刻关闭；为 false 时保持连接
  bool dropConnections = true;

  Uri get uri => Uri.parse('ws://127.0.0.1:${_server.port}');

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      if (!WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
        return;
      }
      final socket = await WebSocketTransformer.upgrade(request);
      connections++;
      if (dropConnections) {
        await socket.close();
      } else {
        // 保持连接，直到测试结束
        socket.listen((_) {}, onDone: () {});
      }
    });
  }

  Future<void> stop() async {
    await _server.close(force: true);
  }
}

void main() {
  test('断线后会持续重连，而不是只重连一次就永久失联', () async {
    final server = _FlakyServer();
    await server.start();
    addTearDown(server.stop);

    var reconnectNotified = 0;
    var closeNotified = 0;

    final ws = WebScoketUtils(
      url: server.uri.toString(),
      heartBeatTime: 60000,
      maxReconnectTime: 3,
      reconnectInterval: const Duration(milliseconds: 50),
      onReconnect: () => reconnectNotified++,
      onClose: (_) => closeNotified++,
    );
    addTearDown(ws.close);

    ws.connect();

    // 等待首次连接 + 3 次重连全部发生
    await Future.delayed(const Duration(seconds: 3));

    // 1 次初始连接 + maxReconnectTime 次重连
    expect(
      server.connections,
      greaterThan(2),
      reason: '断线后必须反复重连；只连了 ${server.connections} 次说明重连定时器被自己取消了',
    );
    expect(reconnectNotified, 1, reason: '一次断线只提示一次，不刷屏');
    expect(closeNotified, 1, reason: '重连次数用尽后才上报断开');
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('收到消息会停掉待执行的重连，不会把已恢复的连接踢掉', () async {
    final server = _FlakyServer();
    await server.start();
    addTearDown(server.stop);

    final ws = WebScoketUtils(
      url: server.uri.toString(),
      heartBeatTime: 60000,
      maxReconnectTime: 5,
      reconnectInterval: const Duration(milliseconds: 200),
    );
    addTearDown(ws.close);

    ws.connect();
    await Future.delayed(const Duration(milliseconds: 100));
    final before = server.connections;

    // 模拟通信恢复
    ws.receiveMessage('ping');
    await Future.delayed(const Duration(milliseconds: 600));

    expect(server.connections, before, reason: 'receiveMessage 之后不应再有新的重连');
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('close() 之后不再自动重连', () async {
    final server = _FlakyServer();
    await server.start();
    addTearDown(server.stop);

    final ws = WebScoketUtils(
      url: server.uri.toString(),
      heartBeatTime: 60000,
      maxReconnectTime: 5,
      reconnectInterval: const Duration(milliseconds: 50),
    );

    ws.connect();
    await Future.delayed(const Duration(milliseconds: 100));
    ws.close();
    final after = server.connections;

    await Future.delayed(const Duration(milliseconds: 500));

    expect(server.connections, after, reason: '主动关闭后必须停止重连');
  }, timeout: const Timeout(Duration(seconds: 20)));
}
