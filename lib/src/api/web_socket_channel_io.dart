import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

WebSocketChannel connectWebSocket(String url, {Iterable<String> protocols}) =>
    IOWebSocketChannel.connect(url, protocols: protocols);
