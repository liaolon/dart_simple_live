import 'dart:convert';
import 'dart:math';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/convert_helper.dart';
import 'package:simple_live_core/src/common/http_client.dart';
import 'package:simple_live_core/src/scripts/douyin_sign.dart';

class DouyinSite implements LiveSite {
  @override
  String id = "douyin";

  @override
  String name = "抖音直播";

  @override
  LiveDanmaku getDanmaku() => DouyinDanmaku();

  /// 使用 QQBrowser User-Agent（参考 DouyinLiveRecorder）
  static const String kDefaultUserAgent =
      "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.5845.97 Safari/537.36 Core/1.116.567.400 QQBrowser/19.7.6764.400";

  static const String kDefaultReferer = "https://live.douyin.com";

  /// 抖音一级分类 -> B 站一级分类（用于图标兜底）。
  static const Map<String, String> kDouyinTopAlias = {
    "聊天": "聊天室",
    "音乐": "电台",
    "游戏": "网游",
    "二次元": "虚拟主播",
    "舞蹈": "娱乐",
    "文化": "知识",
    "生活": "生活",
    "运动": "赛事",
  };

  static const String kDefaultAuthority = "live.douyin.com";

  /// 默认 Cookie - 只需要 ttwid 字段即可获取所有画质（包括蓝光）
  /// 经过测试验证，LOGIN_STATUS=1 等其他字段都是可选的
  static const String kDefaultCookie =
      "ttwid=1%7CB1qls3GdnZhUov9o2NxOMxxYS2ff6OSvEWbv0ytbES4%7C1680522049%7C280d802d6d478e3e78d0c807f7c487e7ffec0ae4e5fdd6a0fe74c3c6af149511";

  /// 用户设置的 cookie
  String cookie = "";

  /// B 站直播分类图标缓存（名称 -> 图标 URL），用于给抖音分类配图标。
  Map<String, String>? _biliIconCache;

  void _logDebug(String msg) {
    // 同时使用 print 和 CoreLog 确保日志输出
    print("[Douyin] $msg");
    CoreLog.d("[Douyin] $msg");
  }

  Map<String, dynamic> headers = {
    "Authority": kDefaultAuthority,
    "Referer": kDefaultReferer,
    "User-Agent": kDefaultUserAgent,
  };

  Future<Map<String, dynamic>> getRequestHeaders() async {
    try {
      // 如果用户已设置 cookie，直接使用用户的 cookie
      if (cookie.isNotEmpty) {
        headers["cookie"] = cookie;
        return headers;
      }

      // 使用默认的 ttwid cookie（只需要 ttwid 即可获取所有画质）
      headers["cookie"] = kDefaultCookie;
      return headers;
    } catch (e) {
      CoreLog.error(e);
      if (!(headers["cookie"]?.toString().isNotEmpty ?? false)) {
        headers["cookie"] = kDefaultCookie;
      }
      return headers;
    }
  }

  @override
  Future<List<LiveCategory>> getCategores() async {
    List<LiveCategory> categories = [];
    var result = await HttpClient.instance.getText(
      "https://live.douyin.com/",
      queryParameters: {},
      header: await getRequestHeaders(),
    );

    // 修复：抖音首页把分类数据放在一段 JS 字符串里，原正则在字段变化时容易截断。
    // 这里用括号配对的方式截取完整的 categoryData 数组后再解析。
    var marker = r'\"categoryData\":[';
    var start = result.indexOf(marker);
    if (start < 0) {
      throw const FormatException("douyin categoryData not found");
    }
    var arrayStart = result.indexOf('[', start);
    var depth = 0;
    var end = -1;
    var inString = false;
    for (var i = arrayStart; i < result.length; i++) {
      if (result[i] == '\\' && i + 1 < result.length && result[i + 1] == '"') {
        i++;
        inString = !inString;
        continue;
      }
      if (inString) {
        continue;
      }
      if (result[i] == '[') {
        depth++;
      } else if (result[i] == ']') {
        depth--;
        if (depth == 0) {
          end = i;
          break;
        }
      }
    }
    if (end < 0) {
      throw const FormatException("douyin categoryData array not closed");
    }
    var categoryJson = result.substring(arrayStart, end + 1);
    categoryJson = categoryJson.replaceAll(r'\"', '"').replaceAll(r'\/', '/');
    var renderDataJson = json.decode(categoryJson);
    var iconMap = await _getBilibiliIconMap();
    for (var item in renderDataJson) {
      var id = '${item["partition"]["id_str"]},${item["partition"]["type"]}';
      var name = asT<String?>(item["partition"]["title"]) ?? "";
      List<LiveSubCategory> subs = [];
      var seen = <String>{};
      // 抖音分类最多三级：分区 -> 子分区 -> 具体游戏。
      // 这里把具体游戏铺平为二级子分类，和其他平台保持一致。
      for (var subItem in item["sub_partition"]) {
        for (var leafItem in subItem["sub_partition"]) {
          var leaf = leafItem["partition"];
          var leafName = asT<String?>(leaf["title"]) ?? "";
          var leafId = '${leaf["id_str"]},${leaf["type"]}';
          if (!seen.add(leafId)) {
            continue;
          }
          subs.add(
            LiveSubCategory(
              id: leafId,
              name: leafName,
              parentId: id,
              pic: _iconForName(
                leafName,
                iconMap,
                fallback: iconMap["网游"] ?? "",
              ),
            ),
          );
        }
      }
      // 没有子分类的分区（聊天/音乐等）补一个“全部”入口。
      if (subs.isEmpty) {
        subs.add(
          LiveSubCategory(
            id: id,
            name: name,
            parentId: id,
            pic: _iconForName(
              name,
              iconMap,
              fallback: iconMap[kDouyinTopAlias[name] ?? ""] ?? "",
            ),
          ),
        );
      }
      categories.add(LiveCategory(children: subs, id: id, name: name));
    }
    return categories;
  }

  Future<Map<String, String>> _getBilibiliIconMap() async {
    if (_biliIconCache != null) {
      return _biliIconCache!;
    }
    var map = <String, String>{};
    try {
      var result = await HttpClient.instance.getJson(
        "https://api.live.bilibili.com/room/v1/Area/getList",
        queryParameters: {"need_entrance": 1, "parent_id": 0},
        header: {
          "User-Agent": kDefaultUserAgent,
          "Referer": "https://live.bilibili.com",
        },
      );
      for (var top in result["data"]) {
        for (var sub in top["list"]) {
          var name = asT<String?>(sub["name"]) ?? "";
          var pic = asT<String?>(sub["pic"]) ?? "";
          if (pic.isNotEmpty) {
            pic = "$pic@100w.png";
          }
          if (name.isNotEmpty && pic.isNotEmpty) {
            map.putIfAbsent(name, () => pic);
          }
        }
        var topName = asT<String?>(top["name"]) ?? "";
        var allPic = "";
        for (var sub in top["list"]) {
          var n = asT<String?>(sub["name"]) ?? "";
          if (n.startsWith("全部")) {
            allPic = asT<String?>(sub["pic"]) ?? "";
            if (allPic.isNotEmpty) allPic = "$allPic@100w.png";
            break;
          }
        }
        if (topName.isNotEmpty && allPic.isNotEmpty) {
          map.putIfAbsent(topName, () => allPic);
        }
      }
    } catch (e) {
      CoreLog.error(e);
    }
    _biliIconCache = map;
    return map;
  }

  String _iconForName(
    String name,
    Map<String, String> iconMap, {
    String fallback = "",
  }) {
    if (name.isEmpty || iconMap.isEmpty) {
      return "";
    }
    var exact = iconMap[name];
    if (exact != null && exact.isNotEmpty) {
      return exact;
    }
    var best = "";
    var bestLen = 0;
    for (var entry in iconMap.entries) {
      var key = entry.key;
      if (key.isEmpty) {
        continue;
      }
      if (name.contains(key) || key.contains(name)) {
        if (key.length > bestLen) {
          bestLen = key.length;
          best = entry.value;
        }
      }
    }
    return best.isNotEmpty ? best : fallback;
  }

  /// 抖音没有公开的“推荐”接口，这里把多个一级分区的房间聚合成一条推荐流，
  /// 避免像以前那样只盯着单个分区，翻来覆去就十几个房间。
  /// 按内容量排序；720 是抖音 web 端的历史“推荐”分区，
  /// 现已不在首页分类表里，放到最后做兜底。
  static const List<String> kRecommendPartitions = [
    '103,4', // 游戏
    '102,4', // 音乐
    '101,4', // 聊天
    '104,4', // 二次元
    '105,4', // 舞蹈
    '106,4', // 文化
    '107,4', // 生活
    '108,4', // 运动
    '720,1', // 历史“推荐”分区（可能已失效）
  ];

  /// 每次翻页取几个分区，轮换着来
  static const int kRecommendPartitionsPerPage = 3;

  /// 单个分区单页的条数（接口一次最多给这么多）
  static const int kPartitionPageSize = 15;

  Future<List<LiveRoomItem>> _getPartitionRooms({
    required String partition,
    required String partitionType,
    int offset = 0,
    int count = kPartitionPageSize,
  }) async {
    String serverUrl =
        "https://live.douyin.com/webcast/web/partition/detail/room/v2/";
    var uri = Uri.parse(serverUrl).replace(
      scheme: "https",
      port: 443,
      queryParameters: {
        "aid": '6383',
        "app_name": "douyin_web",
        "live_id": '1',
        "device_platform": "web",
        "language": "zh-CN",
        "enter_from": "link_share",
        "cookie_enabled": "true",
        "screen_width": "1980",
        "screen_height": "1080",
        "browser_language": "zh-CN",
        "browser_platform": "Win32",
        "browser_name": "Edge",
        "browser_version": "125.0.0.0",
        "browser_online": "true",
        "count": count.toString(),
        "offset": offset.toString(),
        "partition": partition,
        "partition_type": partitionType,
        "req_from": '2',
      },
    );
    var requestUrl = DouyinSign.getAbogusUrl(uri.toString(), kDefaultUserAgent);

    var result = await HttpClient.instance.getJson(
      requestUrl,
      header: await getRequestHeaders(),
    );

    var data = result["data"]?["data"];
    if (data is! List) {
      return <LiveRoomItem>[];
    }
    var items = <LiveRoomItem>[];
    for (var raw in data) {
      if (raw is! Map) {
        continue;
      }
      var room = raw["room"];
      if (room is! Map) {
        continue;
      }
      var coverList = room["cover"]?["url_list"];
      var cover = (coverList is List && coverList.isNotEmpty)
          ? coverList[0]
          : "";
      var online =
          int.tryParse(
            room["room_view_stats"]?["display_value"]?.toString() ?? "",
          ) ??
          0;
      items.add(
        LiveRoomItem(
          roomId: raw["web_rid"]?.toString() ?? "",
          title: room["title"]?.toString() ?? "",
          cover: cover.toString(),
          userName: room["owner"]?["nickname"]?.toString() ?? "",
          online: online,
        ),
      );
    }
    return items;
  }

  @override
  Future<LiveCategoryResult> getCategoryRooms(
    LiveSubCategory category, {
    int page = 1,
  }) async {
    var ids = category.id.split(',');
    var partitionId = ids[0];
    var partitionType = ids[1];

    String serverUrl =
        "https://live.douyin.com/webcast/web/partition/detail/room/v2/";
    var uri = Uri.parse(serverUrl).replace(
      scheme: "https",
      port: 443,
      queryParameters: {
        "aid": '6383',
        "app_name": "douyin_web",
        "live_id": '1',
        "device_platform": "web",
        "language": "zh-CN",
        "enter_from": "link_share",
        "cookie_enabled": "true",
        "screen_width": "1980",
        "screen_height": "1080",
        "browser_language": "zh-CN",
        "browser_platform": "Win32",
        "browser_name": "Edge",
        "browser_version": "125.0.0.0",
        "browser_online": "true",
        "count": '15',
        "offset": ((page - 1) * 15).toString(),
        "partition": partitionId,
        "partition_type": partitionType,
        "req_from": '2',
      },
    );
    var requestUrl = DouyinSign.getAbogusUrl(uri.toString(), kDefaultUserAgent);

    var result = await HttpClient.instance.getJson(
      requestUrl,
      header: await getRequestHeaders(),
    );

    var hasMore = (result["data"]["data"] as List).length >= 15;
    var items = <LiveRoomItem>[];
    for (var item in result["data"]["data"]) {
      var roomItem = LiveRoomItem(
        roomId: item["web_rid"],
        title: item["room"]["title"].toString(),
        cover: item["room"]["cover"]["url_list"][0].toString(),
        userName: item["room"]["owner"]["nickname"].toString(),
        online:
            int.tryParse(
              item["room"]["room_view_stats"]["display_value"].toString(),
            ) ??
            0,
      );
      items.add(roomItem);
    }
    return LiveCategoryResult(hasMore: hasMore, items: items);
  }

  @override
  Future<LiveCategoryResult> getRecommendRooms({int page = 1}) async {
    var total = kRecommendPartitions.length;
    var start = ((page - 1) * kRecommendPartitionsPerPage) % total;
    // 分区池轮完一圈后，再整体往后翻一页
    var offset =
        ((page - 1) * kRecommendPartitionsPerPage ~/ total) *
        kPartitionPageSize;

    var batches = await Future.wait(
      List.generate(kRecommendPartitionsPerPage, (index) {
        var ids = kRecommendPartitions[(start + index) % total].split(',');
        return _getPartitionRooms(
          partition: ids[0],
          partitionType: ids[1],
          offset: offset,
        ).catchError((Object e) {
          CoreLog.error(e);
          return <LiveRoomItem>[];
        });
      }),
    );

    // 各分区轮流取房间，既保证多样性，也避免重复
    var seen = <String>{};
    var items = <LiveRoomItem>[];
    var maxLength = batches.fold<int>(
      0,
      (max, batch) => batch.length > max ? batch.length : max,
    );
    for (var index = 0; index < maxLength; index++) {
      for (var batch in batches) {
        if (index >= batch.length) {
          continue;
        }
        var room = batch[index];
        if (room.roomId.isEmpty) {
          continue;
        }
        if (seen.add(room.roomId)) {
          items.add(room);
        }
      }
    }

    // “推荐”按人气排序，保证首屏拿到的是热门房间
    items.sort((a, b) => b.online.compareTo(a.online));

    return LiveCategoryResult(
      hasMore: batches.any((batch) => batch.length >= kPartitionPageSize),
      items: items,
    );
  }

  /// 当前 cookie 是否带登录态（sessionid）。
  bool get hasLoginSession {
    var text = cookie.toLowerCase();
    return text.contains("sessionid=") || text.contains("sessionid_ss=");
  }

  /// 关注流：当前账号关注的主播里正在直播的房间。
  ///
  /// 需要登录态（未登录时接口返回 20003）。
  /// 这是抖音直播网页版「关注」tab 实际请求的接口：
  /// `/webcast/feed/follow_top/`，必须带 `enter_source` 等参数，否则返回 10011。
  Future<LiveCategoryResult> getFollowRooms({int page = 1}) async {
    const serverUrl = "https://live.douyin.com/webcast/feed/follow_top/";
    var uri = Uri.parse(serverUrl).replace(
      scheme: "https",
      port: 443,
      queryParameters: {
        "aid": '6383',
        "app_name": "douyin_web",
        "live_id": '1',
        "device_platform": "web",
        "language": "zh-CN",
        "enter_from": "link_share",
        "cookie_enabled": "true",
        "screen_width": "2560",
        "screen_height": "1440",
        "browser_language": "zh-CN",
        "browser_platform": "Win32",
        "browser_name": "Chrome",
        "browser_version": "155.0.0.0",
        "os_name": "Windows",
        "os_version": "10",
        "enter_source": "homepage_pc_followtop",
        "need_pinned_info": "0",
        "follow_session_id": "0",
        "source_key": "web_homepage_follow_top",
        "webcast_version_code": "170400",
        "version_code": "170400",
        "need_map": "1",
        "count": kPartitionPageSize.toString(),
        "offset": ((page - 1) * kPartitionPageSize).toString(),
      },
    );
    var requestUrl = DouyinSign.getAbogusUrl(uri.toString(), kDefaultUserAgent);

    // 关注流对 UA 敏感：参数里声明的是 Chrome，
    // 用默认的 QQBrowser UA 会拿到 status=0 但空列表。
    const followUa =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/155.0.0.0 Safari/537.36";
    var headers = await getRequestHeaders();
    headers["User-Agent"] = followUa;

    var result = await HttpClient.instance.getJson(requestUrl, header: headers);

    if (result["status_code"] != 0) {
      // 20003 = 未登录，其它错误同样按空处理，交给上层回退到本地关注
      CoreLog.w("抖音关注流不可用: ${result["status_code"]}");
      return LiveCategoryResult(hasMore: false, items: <LiveRoomItem>[]);
    }

    var items = _parseFeedRooms(result["data"], followed: true);
    return LiveCategoryResult(
      hasMore: items.length >= kPartitionPageSize,
      items: items,
    );
  }

  /// 登录态下的「推荐」直播流（抖音首页推荐 tab 用的接口）。
  ///
  /// 未登录也能拿到一份公共推荐；登录后会带上账号画像，内容明显更贴近自己。
  /// 这是「热门」的正确来源，分区聚合只在它失败时兜底。
  Future<LiveCategoryResult> getRecommendFeed({int page = 1}) async {
    const serverUrl = "https://live.douyin.com/webcast/feed/";
    var uri = Uri.parse(serverUrl).replace(
      scheme: "https",
      port: 443,
      queryParameters: {
        "aid": '6383',
        "app_name": "douyin_web",
        "live_id": '1',
        "device_platform": "web",
        "language": "zh-CN",
        "enter_from": "link_share",
        "cookie_enabled": "true",
        "screen_width": "2560",
        "screen_height": "1440",
        "browser_language": "zh-CN",
        "browser_platform": "Win32",
        "browser_name": "Chrome",
        "browser_version": "155.0.0.0",
        "os_name": "Windows",
        "os_version": "10",
        "count": kPartitionPageSize.toString(),
        "offset": ((page - 1) * kPartitionPageSize).toString(),
      },
    );
    var requestUrl = DouyinSign.getAbogusUrl(uri.toString(), kDefaultUserAgent);

    var headers = await getRequestHeaders();
    headers["User-Agent"] = _chromeUa;

    var result = await HttpClient.instance.getJson(requestUrl, header: headers);

    if (result["status_code"] != 0) {
      CoreLog.w("抖音推荐流不可用: ${result["status_code"]}");
      return LiveCategoryResult(hasMore: false, items: <LiveRoomItem>[]);
    }

    var items = _parseFeedRooms(result["data"]);
    return LiveCategoryResult(
      hasMore: items.length >= kPartitionPageSize,
      items: items,
    );
  }

  static const String _chromeUa =
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/155.0.0.0 Safari/537.36";

  /// 解析 feed 类接口的 `data`（兼容 `[...]` 与 `{"data":[...]}` 两种结构）。
  List<LiveRoomItem> _parseFeedRooms(dynamic data, {bool followed = false}) {
    var list = data is List ? data : (data is Map ? data["data"] : null);
    if (list is! List) {
      return <LiveRoomItem>[];
    }
    var items = <LiveRoomItem>[];
    for (var raw in list) {
      var room = raw is Map ? raw["data"] : null;
      if (room is! Map) {
        continue;
      }
      var coverList = room["cover"]?["url_list"];
      var cover = (coverList is List && coverList.isNotEmpty)
          ? coverList[0]
          : "";
      var owner = room["owner"];
      var stats = room["room_view_stats"];
      var online =
          int.tryParse(
            (stats is Map ? stats["display_value"] : null)?.toString() ?? "",
          ) ??
          int.tryParse(room["user_count"]?.toString() ?? "") ??
          0;
      // 直播间要用「主播 short_id」当 web_rid 才能进房；
      // room.id_str 是 19 位一次性房间号，旧的 reflow 接口已失效。
      var roomId = "";
      if (owner is Map) {
        roomId = (owner["short_id"] ?? owner["web_rid"] ?? "").toString();
      }
      if (roomId.isEmpty && raw is Map) {
        roomId = (raw["web_rid"] ?? "").toString();
      }
      if (roomId.isEmpty) {
        roomId = (room["id_str"] ?? room["id"] ?? "").toString();
      }
      if (roomId.isEmpty) {
        continue;
      }
      items.add(
        LiveRoomItem(
          roomId: roomId,
          title: room["title"]?.toString() ?? "",
          cover: cover.toString(),
          userName: owner is Map ? (owner["nickname"]?.toString() ?? "") : "",
          online: online,
          isFollowed: followed,
        ),
      );
    }
    return items;
  }

  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) async {
    // 有两种roomId，一种是webRid，一种是roomId
    // roomId是一次性的，用户每次重新开播都会生成一个新的roomId
    // roomId一般长度为19位，例如：7376429659866598196
    // webRid是固定的，用户每次开播都是同一个webRid
    // webRid一般长度为11-12位，例如：416144012050
    // 这里简单进行判断，如果roomId长度小于15，则认为是webRid
    if (roomId.length <= 16) {
      var webRid = roomId;
      return await getRoomDetailByWebRid(webRid);
    }

    return await getRoomDetailByRoomId(roomId);
  }

  /// 通过roomId获取直播间信息
  /// - [roomId] 直播间ID
  /// - 返回直播间信息
  Future<LiveRoomDetail> getRoomDetailByRoomId(String roomId) async {
    // 读取房间信息
    var roomData = await _getRoomDataByRoomId(roomId);

    // 通过房间信息获取WebRid
    var webRid = roomData["data"]["room"]["owner"]["web_rid"].toString();

    // 读取用户唯一ID，用于弹幕连接
    // 似乎这个参数不是必须的，先随机生成一个
    //var userUniqueId = await _getUserUniqueId(webRid);
    var userUniqueId = generateRandomNumber(12).toString();

    var room = roomData["data"]["room"];
    var owner = room["owner"];

    var status = asT<int?>(room["status"]) ?? 0;

    // roomId是一次性的，用户每次重新开播都会生成一个新的roomId
    // 所以如果roomId对应的直播间状态不是直播中，就通过webRid获取直播间信息
    if (status == 4) {
      var result = await getRoomDetailByWebRid(webRid);
      return result;
    }

    var roomStatus = status == 2;
    // 主要是为了获取cookie,用于弹幕websocket连接
    var headers = await getRequestHeaders();

    return LiveRoomDetail(
      roomId: webRid,
      title: room["title"].toString(),
      cover: roomStatus ? room["cover"]["url_list"][0].toString() : "",
      userName: owner["nickname"].toString(),
      userAvatar: owner["avatar_thumb"]["url_list"][0].toString(),
      online: roomStatus
          ? asT<int?>(room["room_view_stats"]["display_value"]) ?? 0
          : 0,
      status: roomStatus,
      url: "https://live.douyin.com/$webRid",
      introduction: owner["signature"].toString(),
      notice: "",
      danmakuData: DouyinDanmakuArgs(
        webRid: webRid,
        roomId: roomId,
        userId: userUniqueId,
        cookie: headers["cookie"],
      ),
      data: room["stream_url"],
    );
  }

  /// 通过WebRid获取直播间信息
  /// - [webRid] 直播间RID
  /// - 返回直播间信息
  Future<LiveRoomDetail> getRoomDetailByWebRid(String webRid) async {
    try {
      var result = await _getRoomDetailByWebRidApi(webRid);
      return result;
    } catch (e) {
      CoreLog.error(e);
    }
    return await _getRoomDetailByWebRidHtml(webRid);
  }

  /// 通过WebRid访问直播间API，从API中获取直播间信息
  /// - [webRid] 直播间RID
  /// - 返回直播间信息
  Future<LiveRoomDetail> _getRoomDetailByWebRidApi(String webRid) async {
    // 读取房间信息
    var data = await _getRoomDataByApi(webRid);

    var roomData = data["data"][0];
    var userData = data["user"];
    var roomId = roomData["id_str"].toString();

    // 读取用户唯一ID，用于弹幕连接
    // 似乎这个参数不是必须的，先随机生成一个
    //var userUniqueId = await _getUserUniqueId(webRid);
    var userUniqueId = generateRandomNumber(12).toString();

    var owner = roomData["owner"];

    var roomStatus = (asT<int?>(roomData["status"]) ?? 0) == 2;

    // 主要是为了获取cookie,用于弹幕websocket连接
    var headers = await getRequestHeaders();
    return LiveRoomDetail(
      roomId: webRid,
      title: roomData["title"].toString(),
      cover: roomStatus ? roomData["cover"]["url_list"][0].toString() : "",
      userName: roomStatus
          ? owner["nickname"].toString()
          : userData["nickname"].toString(),
      userAvatar: roomStatus
          ? owner["avatar_thumb"]["url_list"][0].toString()
          : userData["avatar_thumb"]["url_list"][0].toString(),
      online: roomStatus
          ? asT<int?>(roomData["room_view_stats"]["display_value"]) ?? 0
          : 0,
      status: roomStatus,
      url: "https://live.douyin.com/$webRid",
      introduction: owner?["signature"]?.toString() ?? "",
      notice: "",
      danmakuData: DouyinDanmakuArgs(
        webRid: webRid,
        roomId: roomId,
        userId: userUniqueId,
        cookie: headers["cookie"],
      ),
      data: roomStatus ? roomData["stream_url"] : {},
    );
  }

  /// 通过WebRid访问直播间网页，从网页HTML中获取直播间信息
  /// - [webRid] 直播间RID
  /// - 返回直播间信息
  Future<LiveRoomDetail> _getRoomDetailByWebRidHtml(String webRid) async {
    var roomData = await _getRoomDataByHtml(webRid);
    var roomId = roomData["roomStore"]["roomInfo"]["room"]["id_str"].toString();
    var userUniqueId = roomData["userStore"]["odin"]["user_unique_id"]
        .toString();

    var room = roomData["roomStore"]["roomInfo"]["room"];
    var owner = room["owner"];
    var anchor = roomData["roomStore"]["roomInfo"]["anchor"];
    var roomStatus = (asT<int?>(room["status"]) ?? 0) == 2;

    // 主要是为了获取cookie,用于弹幕websocket连接
    var headers = await getRequestHeaders();

    return LiveRoomDetail(
      roomId: webRid,
      title: room["title"].toString(),
      cover: roomStatus ? room["cover"]["url_list"][0].toString() : "",
      userName: roomStatus
          ? owner["nickname"].toString()
          : anchor["nickname"].toString(),
      userAvatar: roomStatus
          ? owner["avatar_thumb"]["url_list"][0].toString()
          : anchor["avatar_thumb"]["url_list"][0].toString(),
      online: roomStatus
          ? asT<int?>(room["room_view_stats"]["display_value"]) ?? 0
          : 0,
      status: roomStatus,
      url: "https://live.douyin.com/$webRid",
      introduction: owner?["signature"]?.toString() ?? "",
      notice: "",
      danmakuData: DouyinDanmakuArgs(
        webRid: webRid,
        roomId: roomId,
        userId: userUniqueId,
        cookie: headers["cookie"],
      ),
      data: roomStatus ? room["stream_url"] : {},
    );
  }

  /// 读取用户的唯一ID
  /// - [webRid] 直播间RID
  // ignore: unused_element
  Future<String> _getUserUniqueId(String webRid) async {
    try {
      var webInfo = await _getRoomDataByHtml(webRid);
      return webInfo["userStore"]["odin"]["user_unique_id"].toString();
    } catch (e) {
      return generateRandomNumber(12).toString();
    }
  }

  /// 进入直播间前需要先获取cookie
  /// - [webRid] 直播间RID
  Future<String> _getWebCookie(String webRid) async {
    var headResp = await HttpClient.instance.head(
      "https://live.douyin.com/$webRid",
      header: headers,
    );
    var dyCookie = "";
    headResp.headers["set-cookie"]?.forEach((element) {
      var cookie = element.split(";")[0];
      if (cookie.contains("ttwid")) {
        dyCookie += "$cookie;";
      }
      if (cookie.contains("__ac_nonce")) {
        dyCookie += "$cookie;";
      }
      if (cookie.contains("msToken")) {
        dyCookie += "$cookie;";
      }
    });
    return dyCookie;
  }

  /// 通过webRid获取直播间Web信息
  /// - [webRid] 直播间RID
  Future<Map> _getRoomDataByHtml(String webRid) async {
    var dyCookie = await _getWebCookie(webRid);
    var result = await HttpClient.instance.getText(
      "https://live.douyin.com/$webRid",
      queryParameters: {},
      header: {
        "Authority": kDefaultAuthority,
        "Referer": kDefaultReferer,
        "Cookie": dyCookie,
        "User-Agent": kDefaultUserAgent,
      },
    );

    var renderData =
        RegExp(
          r'\{\\"state\\":\{\\"appStore.*?\]\\n',
        ).firstMatch(result)?.group(0) ??
        "";
    var str = renderData
        .trim()
        .replaceAll('\\"', '"')
        .replaceAll(r"\\", r"\")
        .replaceAll(']\\n', "");
    var renderDataJson = json.decode(str);
    return renderDataJson["state"];
  }

  /// 通过webRid获取直播间Web信息
  /// - [webRid] 直播间RID
  Future<Map> _getRoomDataByApi(String webRid) async {
    String serverUrl = "https://live.douyin.com/webcast/room/web/enter/";

    // 提前获取 headers
    var requestHeader = await getRequestHeaders();

    // 使用动态 Referer（包含房间号，参考 DouyinLiveRecorder）
    requestHeader["Referer"] = "https://live.douyin.com/$webRid";

    var uri = Uri.parse(serverUrl).replace(
      scheme: "https",
      port: 443,
      queryParameters: {
        "aid": '6383',
        "app_name": "douyin_web",
        "live_id": '1',
        "device_platform": "web",
        "language": "zh-CN",
        "browser_language": "zh-CN",
        "browser_platform": "Win32",
        "browser_name": "Chrome",
        "browser_version": "125.0.0.0",
        "web_rid": webRid,
        "msToken": "",
      },
    );
    var requestUrl = DouyinSign.getAbogusUrl(uri.toString(), kDefaultUserAgent);

    var result = await HttpClient.instance.getJson(
      requestUrl,
      header: requestHeader,
    );

    if (result is! Map) {
      throw Exception("抖音接口返回格式异常");
    }

    return result["data"];
  }

  /// 通过roomId获取直播间信息
  /// - [roomId] 直播间ID
  Future<Map> _getRoomDataByRoomId(String roomId) async {
    var result = await HttpClient.instance.getJson(
      'https://webcast.amemv.com/webcast/room/reflow/info/',
      queryParameters: {
        "type_id": 0,
        "live_id": 1,
        "room_id": roomId,
        "sec_user_id": "",
        "version_code": "99.99.99",
        "app_id": 6383,
      },
      header: await getRequestHeaders(),
    );
    return result;
  }

  @override
  Future<List<LivePlayQuality>> getPlayQualites({
    required LiveRoomDetail detail,
  }) async {
    List<LivePlayQuality> qualities = [];

    try {
      var liveCoreData = detail.data["live_core_sdk_data"];

      if (liveCoreData == null) {
        return qualities;
      }

      var pullData = liveCoreData["pull_data"];

      if (pullData == null) {
        return qualities;
      }

      var options = pullData["options"];

      var qulityList = options?["qualities"];

      var streamData = pullData["stream_data"]?.toString() ?? "";

      if (!streamData.startsWith('{')) {
        var flvList = (detail.data["flv_pull_url"] as Map).values
            .cast<String>()
            .toList();
        var hlsList = (detail.data["hls_pull_url_map"] as Map).values
            .cast<String>()
            .toList();
        for (var quality in qulityList) {
          int level = quality["level"];
          List<String> urls = [];
          var flvIndex = flvList.length - level;
          if (flvIndex >= 0 && flvIndex < flvList.length) {
            urls.add(flvList[flvIndex]);
          }
          var hlsIndex = hlsList.length - level;
          if (hlsIndex >= 0 && hlsIndex < hlsList.length) {
            urls.add(hlsList[hlsIndex]);
          }
          var qualityItem = LivePlayQuality(
            quality: quality["name"],
            sort: level,
            data: urls,
          );
          if (urls.isNotEmpty) {
            qualities.add(qualityItem);
          }
        }
      } else {
        var qualityData = json.decode(streamData)["data"] as Map;

        for (var quality in qulityList) {
          List<String> urls = [];

          var flvUrl = qualityData[quality["sdk_key"]]?["main"]?["flv"]
              ?.toString();

          if (flvUrl != null && flvUrl.isNotEmpty) {
            urls.add(flvUrl);
          }
          var hlsUrl = qualityData[quality["sdk_key"]]?["main"]?["hls"]
              ?.toString();

          if (hlsUrl != null && hlsUrl.isNotEmpty) {
            urls.add(hlsUrl);
          }

          var qualityItem = LivePlayQuality(
            quality: quality["name"],
            sort: quality["level"],
            data: urls,
          );
          if (urls.isNotEmpty) {
            qualities.add(qualityItem);
          }
        }
      }
    } catch (e, stackTrace) {
      CoreLog.error(e);
      CoreLog.error(stackTrace);
    }
    // var qualityData = json.decode(
    //     detail.data["live_core_sdk_data"]["pull_data"]["stream_data"])["data"];

    qualities.sort((a, b) => b.sort.compareTo(a.sort));
    _logDebug("获取到的画质列表: ${qualities.map((q) => q.quality).toList()}");
    return qualities;
  }

  @override
  Future<LivePlayUrl> getPlayUrls({
    required LiveRoomDetail detail,
    required LivePlayQuality quality,
  }) async {
    // 返回列表的副本，防止外部 clear() 影响原始数据
    return LivePlayUrl(urls: List<String>.from(quality.data));
  }

  @override
  Future<LiveSearchRoomResult> searchRooms(
    String keyword, {
    int page = 1,
  }) async {
    String serverUrl = "https://www.douyin.com/aweme/v1/web/live/search/";
    var uri = Uri.parse(serverUrl).replace(
      scheme: "https",
      port: 443,
      queryParameters: {
        "device_platform": "webapp",
        "aid": "6383",
        "channel": "channel_pc_web",
        "search_channel": "aweme_live",
        "keyword": keyword,
        "search_source": "switch_tab",
        "query_correct_type": "1",
        "is_filter_search": "0",
        "from_group_id": "",
        "offset": ((page - 1) * 10).toString(),
        "count": "10",
        "pc_client_type": "1",
        "version_code": "170400",
        "version_name": "17.4.0",
        "cookie_enabled": "true",
        "screen_width": "1980",
        "screen_height": "1080",
        "browser_language": "zh-CN",
        "browser_platform": "Win32",
        "browser_name": "Edge",
        "browser_version": "125.0.0.0",
        "browser_online": "true",
        "engine_name": "Blink",
        "engine_version": "125.0.0.0",
        "os_name": "Windows",
        "os_version": "10",
        "cpu_core_num": "12",
        "device_memory": "8",
        "platform": "PC",
        "downlink": "10",
        "effective_type": "4g",
        "round_trip_time": "100",
        "webid": "7382872326016435738",
      },
    );
    var requlestUrl = uri.toString();
    var headResp = await HttpClient.instance.head(
      'https://live.douyin.com',
      header: headers,
    );
    var dyCookie = "";
    headResp.headers["set-cookie"]?.forEach((element) {
      var cookie = element.split(";")[0];
      if (cookie.contains("ttwid")) {
        dyCookie += "$cookie;";
      }
      if (cookie.contains("__ac_nonce")) {
        dyCookie += "$cookie;";
      }
    });
    // 搜索接口现在必须登录，优先使用用户设置的登录 Cookie。
    var searchCookie = cookie.isNotEmpty ? cookie : dyCookie;

    var result = await HttpClient.instance.getJson(
      requlestUrl,
      queryParameters: {},
      header: {
        "Authority": 'www.douyin.com',
        'accept': 'application/json, text/plain, */*',
        'accept-language': 'zh-CN,zh;q=0.9,en;q=0.8',
        'cookie': searchCookie,
        'priority': 'u=1, i',
        'referer':
            'https://www.douyin.com/search/${Uri.encodeComponent(keyword)}?type=live',
        'sec-ch-ua':
            '"Microsoft Edge";v="125", "Chromium";v="125", "Not.A/Brand";v="24"',
        'sec-ch-ua-mobile': '?0',
        'sec-ch-ua-platform': '"Windows"',
        'sec-fetch-dest': 'empty',
        'sec-fetch-mode': 'cors',
        'sec-fetch-site': 'same-origin',
        'user-agent': kDefaultUserAgent,
      },
    );
    var items = <LiveRoomItem>[];
    if (result != "" && result != 'blocked') {
      for (var item in result["data"] ?? []) {
        var itemData = json.decode(item["lives"]["rawdata"].toString());
        var roomItem = LiveRoomItem(
          roomId: itemData["owner"]["web_rid"].toString(),
          title: itemData["title"].toString(),
          cover: itemData["cover"]["url_list"][0].toString(),
          userName: itemData["owner"]["nickname"].toString(),
          online: int.tryParse(itemData["stats"]["total_user"].toString()) ?? 0,
        );
        items.add(roomItem);
      }
    }
    var hasMore = false;
    if (items.isEmpty) {
      // 未登录时直播搜索会被拦截，按“分类名”回退到分区直播列表。
      items = await _searchByCategory(keyword);
    } else {
      hasMore = items.length >= 10;
    }
    return LiveSearchRoomResult(hasMore: hasMore, items: items);
  }

  /// 按分类名匹配并返回该分区的直播列表（用于未登录时的搜索回退）。
  Future<List<LiveRoomItem>> _searchByCategory(String keyword) async {
    try {
      var categories = await getCategores();
      var kw = keyword.trim();
      if (kw.isEmpty) {
        return [];
      }
      LiveSubCategory? target;
      for (var c in categories) {
        for (var s in c.children) {
          if (s.name == kw) {
            target = s;
            break;
          }
        }
        if (target != null) {
          break;
        }
      }
      if (target == null) {
        for (var c in categories) {
          for (var s in c.children) {
            if (s.name.contains(kw) || kw.contains(s.name)) {
              target = s;
              break;
            }
          }
          if (target != null) {
            break;
          }
        }
      }
      if (target == null) {
        return [];
      }
      var result = await getCategoryRooms(target, page: 1);
      return result.items;
    } catch (e) {
      CoreLog.error(e);
      return [];
    }
  }

  @override
  Future<LiveSearchAnchorResult> searchAnchors(
    String keyword, {
    int page = 1,
  }) async {
    throw Exception("抖音暂不支持搜索主播，请直接搜索直播间");
  }

  @override
  Future<bool> getLiveStatus({required String roomId}) async {
    var result = await getRoomDetail(roomId: roomId);
    return result.status;
  }

  @override
  Future<List<LiveSuperChatMessage>> getSuperChatMessage({
    required String roomId,
  }) {
    return Future.value(<LiveSuperChatMessage>[]);
  }

  //生成指定长度的16进制随机字符串
  String generateRandomString(int length) {
    var random = Random.secure();
    var values = List<int>.generate(length, (i) => random.nextInt(16));
    StringBuffer stringBuffer = StringBuffer();
    for (var item in values) {
      stringBuffer.write(item.toRadixString(16));
    }
    return stringBuffer.toString();
  }

  // 生成随机的数字
  int generateRandomNumber(int length) {
    var random = Random.secure();
    var values = List<int>.generate(length, (i) => random.nextInt(10));
    StringBuffer stringBuffer = StringBuffer();
    for (var item in values) {
      stringBuffer.write(item);
    }
    return int.tryParse(stringBuffer.toString()) ??
        Random().nextInt(1000000000);
  }
}
