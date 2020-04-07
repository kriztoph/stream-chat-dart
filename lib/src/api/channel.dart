import 'dart:async';

import 'package:dio/dio.dart';
import 'package:rxdart/rxdart.dart';
import 'package:stream_chat/src/event_type.dart';
import 'package:stream_chat/src/models/channel_state.dart';
import 'package:stream_chat/src/models/user.dart';
import 'package:stream_chat/stream_chat.dart';
import 'package:uuid/uuid.dart';

import '../client.dart';
import '../models/event.dart';
import '../models/member.dart';
import '../models/message.dart';
import 'requests.dart';
import 'responses.dart';

/// This a the class that manages a specific channel.
class Channel {
  /// Create a channel client instance.
  Channel(
    this._client,
    this.type,
    this._id,
    this._extraData,
  ) : _cid = _id != null ? "$type:$_id" : null {
    _client.logger.info('New Channel instance not initialized created');
  }

  /// Create a channel client instance from a [ChannelState] object
  Channel.fromState(this._client, ChannelState channelState) {
    _cid = channelState.channel.cid;
    _id = channelState.channel.id;
    type = channelState.channel.type;

    state = ChannelClientState(this, channelState);
    _initializedCompleter.complete(true);
    _startCleaning();

    _client.logger.info('New Channel instance initialized created');
  }

  /// This client state
  ChannelClientState state;

  /// The channel type
  String type;

  String _id;
  String _cid;
  Map<String, dynamic> _extraData;

  /// Channel configuration
  ChannelConfig get config => state?._channelState?.channel?.config;

  /// Channel configuration as a stream
  Stream<ChannelConfig> get configStream =>
      state?.channelStateStream?.map((cs) => cs.channel?.config);

  /// Channel user creator
  User get createdBy => state?._channelState?.channel?.createdBy;

  /// Channel user creator as a stream
  Stream<User> get createdByStream =>
      state?.channelStateStream?.map((cs) => cs.channel?.createdBy);

  /// Channel frozen status
  bool get frozen => state?._channelState?.channel?.frozen;

  /// Channel frozen status as a stream
  Stream<bool> get frozenStream =>
      state?.channelStateStream?.map((cs) => cs.channel?.frozen);

  /// Channel creation date
  DateTime get createdAt => state?._channelState?.channel?.createdAt;

  /// Channel creation date as a stream
  Stream<DateTime> get createdAtStream =>
      state?.channelStateStream?.map((cs) => cs.channel?.createdAt);

  /// Channel last message date
  DateTime get lastMessageAt => state?._channelState?.channel?.lastMessageAt;

  /// Channel last message date as a stream
  Stream<DateTime> get lastMessageAtStream =>
      state?.channelStateStream?.map((cs) => cs.channel?.lastMessageAt);

  /// Channel updated date
  DateTime get updatedAt => state?._channelState?.channel?.updatedAt;

  /// Channel updated date as a stream
  Stream<DateTime> get updatedAtStream =>
      state?.channelStateStream?.map((cs) => cs.channel?.updatedAt);

  /// Channel deletion date
  DateTime get deletedAt => state?._channelState?.channel?.deletedAt;

  /// Channel deletion date as a stream
  Stream<DateTime> get deletedAtStream =>
      state?.channelStateStream?.map((cs) => cs.channel?.deletedAt);

  /// Channel member count
  int get memberCount => state?._channelState?.channel?.memberCount;

  /// Channel member count as a stream
  Stream<int> get memberCountStream =>
      state?.channelStateStream?.map((cs) => cs.channel?.memberCount);

  /// Channel id
  String get id => state?._channelState?.channel?.id ?? _id;

  /// Channel id as a stream
  Stream<String> get idStream =>
      state?.channelStateStream?.map((cs) => cs.channel?.id ?? _id);

  /// Channel cid
  String get cid => state?._channelState?.channel?.cid ?? _cid;

  /// Channel cid as a stream
  Stream<String> get cidStream =>
      state?.channelStateStream?.map((cs) => cs.channel?.cid ?? _cid);

  /// Channel extra data
  Map<String, dynamic> get extraData =>
      state?._channelState?.channel?.extraData;

  /// Channel extra data as a stream
  Stream<Map<String, dynamic>> get extraDataStream =>
      state?.channelStateStream?.map((cs) => cs.channel?.extraData);

  /// The main Stream chat client
  Client get client => _client;
  Client _client;

  String get _channelURL => "/channels/$type/$id";

  Completer<bool> _initializedCompleter = Completer();

  /// True if this is initialized
  /// Call [watch] to initialize the client or instantiate it using [Channel.fromState]
  Future<bool> get initialized => _initializedCompleter.future;

  /// Send a message to this channel
  Future<SendMessageResponse> sendMessage(Message message) async {
    final messageId = message.id ?? Uuid().v4();
    final newMessage = message.copyWith(
      createdAt: DateTime.now(),
      user: _client.state.user,
      id: messageId,
      status: MessageSendingStatus.SENDING,
    );

    if (message.parentId != null) {
      final parentMessage =
          state.messages.firstWhere((m) => m.id == message.parentId);
      _client.handleEvent(Event(
        type: EventType.messageUpdated,
        message: parentMessage.copyWith(
          replyCount: parentMessage.replyCount + 1,
        ),
        cid: cid,
      ));
    }
    _client.handleEvent(Event(
      type: EventType.messageNew,
      message: newMessage,
      cid: cid,
    ));

    try {
      final response = await _client.post(
        "$_channelURL/message",
        data: {
          "message": message
              .copyWith(
                id: messageId,
              )
              .toJson()
        },
      );

      _client.handleEvent(Event(
        type: EventType.messageNew,
        message: newMessage.copyWith(
          status: MessageSendingStatus.SENT,
        ),
        cid: cid,
      ));

      final res = _client.decode(response.data, SendMessageResponse.fromJson);

      if (res.message?.type == 'ephemeral') {
        _client.handleEvent(Event(
          type: EventType.messageUpdated,
          message: res.message,
          cid: cid,
        ));
      }

      return res;
    } catch (error) {
      _client.handleEvent(Event(
        type: EventType.messageUpdated,
        message: newMessage.copyWith(
          status: MessageSendingStatus.FAILED,
        ),
        cid: cid,
      ));
      rethrow;
    }
  }

  /// Send a file to this channel
  Future<SendFileResponse> sendFile(MultipartFile file) async {
    final response = await _client.post(
      "$_channelURL/file",
      data: FormData.fromMap({'file': file}),
    );
    return _client.decode(response.data, SendFileResponse.fromJson);
  }

  /// Send an image to this channel
  Future<SendImageResponse> sendImage(MultipartFile file) async {
    final response = await _client.post(
      "$_channelURL/image",
      data: FormData.fromMap({'file': file}),
    );
    return _client.decode(response.data, SendImageResponse.fromJson);
  }

  /// Delete a file from this channel
  Future<EmptyResponse> deleteFile(String url) async {
    final response = await _client
        .delete("$_channelURL/file", queryParameters: {"url": url});
    return _client.decode(response.data, EmptyResponse.fromJson);
  }

  /// Delete an image from this channel
  Future<EmptyResponse> deleteImage(String url) async {
    final response = await _client
        .delete("$_channelURL/image", queryParameters: {"url": url});
    return _client.decode(response.data, EmptyResponse.fromJson);
  }

  /// Send an event on this channel
  Future<EmptyResponse> sendEvent(Event event) {
    _checkInitialized();
    return _client.post(
      "$_channelURL/event",
      data: {"event": event.toJson()},
    ).then((res) {
      return _client.decode(res.data, EmptyResponse.fromJson);
    });
  }

  /// Send a reaction to this channel
  Future<SendReactionResponse> sendReaction(
    String messageID,
    String type, {
    Map<String, dynamic> extraData = const {},
  }) async {
    final data = Map<String, dynamic>.from(extraData)
      ..addAll({
        "type": type,
      });

    final res = await _client.post(
      "/messages/$messageID/reaction",
      data: {"reaction": data},
    );
    return _client.decode(res.data, SendReactionResponse.fromJson);
  }

  /// Delete a reaction from this channel
  Future<EmptyResponse> deleteReaction(String messageID, String reactionType) {
    _checkInitialized();
    return client
        .delete("/messages/$messageID/reaction/$reactionType")
        .then((res) => _client.decode(res.data, EmptyResponse.fromJson));
  }

  /// Edit the channel custom data
  Future<UpdateChannelResponse> update(
    Map<String, dynamic> channelData,
    Message updateMessage,
  ) async {
    final response = await _client.post(_channelURL, data: {
      'message': updateMessage.toJson(),
      'data': channelData,
    });
    return _client.decode(response.data, UpdateChannelResponse.fromJson);
  }

  /// Delete this channel. Messages are permanently removed.
  Future<EmptyResponse> delete() async {
    final response = await _client.delete(_channelURL);
    return _client.decode(response.data, EmptyResponse.fromJson);
  }

  /// Removes all messages from the channel
  Future<EmptyResponse> truncate() async {
    final response = await _client.post("$_channelURL/truncate");
    return _client.decode(response.data, EmptyResponse.fromJson);
  }

  /// Accept invitation to the channel
  Future<AcceptInviteResponse> acceptInvite([Message message]) async {
    final res = await _client.post(_channelURL,
        data: {"accept_invite": true, "message": message?.toJson()});
    return _client.decode(res.data, AcceptInviteResponse.fromJson);
  }

  /// Reject invitation to the channel
  Future<RejectInviteResponse> rejectInvite([Message message]) async {
    final res = await _client.post(_channelURL,
        data: {"accept_invite": false, "message": message?.toJson()});
    return _client.decode(res.data, RejectInviteResponse.fromJson);
  }

  /// Add members to the channel
  Future<AddMembersResponse> addMembers(
    List<Member> members,
    Message message,
  ) async {
    final res = await _client.post(_channelURL, data: {
      "add_members": members.map((m) => m.toJson()),
      "message": message.toJson(),
    });
    return _client.decode(res.data, AddMembersResponse.fromJson);
  }

  /// Invite members to the channel
  Future<InviteMembersResponse> inviteMembers(
    List<Member> members,
    Message message,
  ) async {
    final res = await _client.post(_channelURL, data: {
      "invites": members.map((m) => m.toJson()),
      "message": message.toJson(),
    });
    return _client.decode(res.data, InviteMembersResponse.fromJson);
  }

  /// Remove members from the channel
  Future<RemoveMembersResponse> removeMembers(
      List<Member> members, Message message) async {
    final res = await _client.post(_channelURL, data: {
      "remove_members": members.map((m) => m.toJson()),
      "message": message.toJson(),
    });
    return _client.decode(res.data, RemoveMembersResponse.fromJson);
  }

  /// Send action for a specific message of this channel
  Future<SendActionResponse> sendAction(
    String messageId,
    Map<String, dynamic> formData,
  ) async {
    _checkInitialized();
    final response = await _client.post("/messages/$messageId/action", data: {
      'id': id,
      'type': type,
      'form_data': formData,
      'message_id': messageId,
    });

    final res = _client.decode(response.data, SendActionResponse.fromJson);

    if (res.message != null) {
      _client.handleEvent(Event(
        message: res.message,
        type: EventType.messageNew,
        cid: cid,
      ));
    } else {
      final oldIndex = state.messages?.indexWhere((m) => m.id == messageId);

      Message oldMessage;
      if (oldIndex != null && oldIndex != -1) {
        oldMessage = state.messages[oldIndex];
        state.updateChannelState(state._channelState.copyWith(
          messages: state.messages..remove(oldMessage),
        ));
      } else {
        oldMessage = state.threads.values
            .expand((messages) => messages)
            .firstWhere((m) => m.id == messageId, orElse: () => null);
        if (oldMessage?.parentId != null) {
          state.updateThreadInfo(oldMessage.parentId,
              state.threads[oldMessage.parentId]..remove(oldMessage));
        }
      }
    }

    return res;
  }

  /// Mark all channel messages as read
  Future<EmptyResponse> markRead() async {
    _checkInitialized();
    final response = await _client.post("$_channelURL/read", data: {});
    return _client.decode(response.data, EmptyResponse.fromJson);
  }

  /// Loads the initial channel state and watches for changes
  Future<ChannelState> watch([Map<String, dynamic> options = const {}]) async {
    final watchOptions = Map<String, dynamic>.from({
      "state": true,
      "watch": true,
      "presence": false,
    })
      ..addAll(options);

    var response;

    try {
      response = await query(options: watchOptions);
    } catch (error, stackTrace) {
      if (!_initializedCompleter.isCompleted) {
        _initializedCompleter.completeError(error, stackTrace);
      }
      rethrow;
    }

    if (state == null) {
      _initState(response);
    }

    return response;
  }

  void _initState(ChannelState channelState) {
    state = ChannelClientState(this, channelState);
    if (!_initializedCompleter.isCompleted) {
      _initializedCompleter.complete(true);
    }
    _startCleaning();
  }

  /// Stop watching the channel
  Future<EmptyResponse> stopWatching() async {
    final response = await _client.post("$_channelURL/stop-watching");
    return _client.decode(response.data, EmptyResponse.fromJson);
  }

  /// List the message replies for a parent message
  Future<QueryRepliesResponse> getReplies(
    String parentId,
    PaginationParams options,
  ) async {
    final cachedReplies = await _client.offlineStorage?.getReplies(parentId);
    state?.updateThreadInfo(parentId, cachedReplies);

    final response = await _client.get("/messages/$parentId/replies",
        queryParameters: options.toJson());

    final repliesResponse = _client.decode<QueryRepliesResponse>(
        response.data, QueryRepliesResponse.fromJson);

    state?.updateThreadInfo(parentId, repliesResponse.messages);

    return repliesResponse;
  }

  /// List the reactions for a message in the channel
  Future<QueryReactionsResponse> getReactions(
    String messageID,
    PaginationParams options,
  ) async {
    final response = await _client.get(
      "/messages/$messageID/reactions",
      queryParameters: options.toJson(),
    );
    return _client.decode<QueryReactionsResponse>(
        response.data, QueryReactionsResponse.fromJson);
  }

  /// Retrieves a list of messages by ID
  Future<GetMessagesByIdResponse> getMessagesById(
      List<String> messageIDs) async {
    final response = await _client.get(
      "$_channelURL/messages",
      queryParameters: {'ids': messageIDs.join(',')},
    );
    return _client.decode<GetMessagesByIdResponse>(
        response.data, GetMessagesByIdResponse.fromJson);
  }

  /// Creates a new channel
  Future<ChannelState> create() async {
    return query(options: {
      "watch": false,
      "state": false,
      "presence": false,
    });
  }

  /// Query the API, get messages, members or other channel fields
  Future<ChannelState> query({
    Map<String, dynamic> options = const {},
    PaginationParams messagesPagination,
    PaginationParams membersPagination,
    PaginationParams watchersPagination,
  }) async {
    var path = "/channels/$type";
    if (id != null) {
      path = "$path/$id";
    }
    path = '$path/query';

    final payload = Map<String, dynamic>.from({
      "state": true,
    })
      ..addAll(options);

    if (_extraData != null) {
      payload['data'] = _extraData;
    }

    if (messagesPagination != null) {
      payload['messages'] = messagesPagination.toJson();
    }
    if (membersPagination != null) {
      payload['members'] = membersPagination.toJson();
    }
    if (watchersPagination != null) {
      payload['watchers'] = watchersPagination.toJson();
    }

    if (cid != null) {
      final updatedState = await _client.offlineStorage?.getChannel(cid);
      if (state == null && updatedState != null) {
        _initState(updatedState);
      }
    }

    final response = await _client.post(path, data: payload);
    final updatedState = _client.decode(response.data, ChannelState.fromJson);

    if (_id == null) {
      _id = updatedState.channel.id;
      _cid = updatedState.channel.cid;
    }

    state?.updateChannelState(updatedState);
    return updatedState;
  }

  /// Mutes the channel
  Future<EmptyResponse> mute({Duration expiration}) async {
    final response = await _client.post('/moderation/mute/channel', data: {
      'channel_cid': cid,
      if (expiration != null) 'expiration': expiration.inMilliseconds,
    });
    return _client.decode(response.data, EmptyResponse.fromJson);
  }

  /// Unmutes the channel
  Future<EmptyResponse> unmute() async {
    final response = await _client.post('/moderation/unmute/channel', data: {
      'channel_cid': cid,
    });
    return _client.decode(response.data, EmptyResponse.fromJson);
  }

  /// Bans a user from the channel
  Future<EmptyResponse> banUser(
    String userID,
    Map<String, dynamic> options,
  ) async {
    _checkInitialized();
    final opts = Map<String, dynamic>.from(options)
      ..addAll({
        'type': type,
        'id': id,
      });
    return _client.banUser(userID, opts);
  }

  /// Remove the ban for a user in the channel
  Future<EmptyResponse> unbanUser(String userID) async {
    _checkInitialized();
    return _client.unbanUser(userID, {
      'type': type,
      'id': id,
    });
  }

  /// Hides the channel from [Client.queryChannels] for the user until a message is added
  ///	If [clearHistory] is set to true - all messages will be removed for the user
  Future<EmptyResponse> hide({bool clearHistory = false}) async {
    _checkInitialized();
    final response = await _client
        .post("$_channelURL/hide", data: {'clear_history': clearHistory});
    return _client.decode(response.data, EmptyResponse.fromJson);
  }

  /// Removes the hidden status for the channel
  Future<EmptyResponse> show() async {
    _checkInitialized();
    final response = await _client.post("$_channelURL/show");
    return _client.decode(response.data, EmptyResponse.fromJson);
  }

  /// Stream of [Event] coming from websocket connection specific for the channel
  /// Pass an eventType as parameter in order to filter just a type of event
  Stream<Event> on([String eventType]) =>
      _client.on(eventType).where((e) => e.cid == cid);

  DateTime _lastTypingEvent;

  /// First of the [EventType.typingStart] and [EventType.typingStop] events based on the users keystrokes.
  /// Call this on every keystroke.
  Future<void> keyStroke() async {
    if (config?.typingEvents == false) {
      return;
    }

    client.logger.info('start typing');
    final now = DateTime.now();

    if (_lastTypingEvent == null ||
        now.difference(_lastTypingEvent).inSeconds >= 2) {
      _lastTypingEvent = now;
      await sendEvent(Event(type: EventType.typingStart));
    }
  }

  /// Sets last typing to null and sends the typing.stop event
  Future<void> stopTyping() async {
    if (config?.typingEvents == false) {
      return;
    }

    client.logger.info('stop typing');
    _lastTypingEvent = null;
    await sendEvent(Event(type: EventType.typingStop));
  }

  Timer _cleaningTimer;

  void _startCleaning() {
    if (config?.typingEvents == false) {
      return;
    }

    _cleaningTimer = Timer.periodic(Duration(milliseconds: 500), (_) {
      final now = DateTime.now();

      if (_lastTypingEvent != null &&
          now.difference(_lastTypingEvent).inSeconds > 1) {
        stopTyping();
      }

      state._clean();
    });
  }

  /// Call this method to dispose the channel client
  void dispose() {
    _cleaningTimer.cancel();
    state.dispose();
  }

  void _checkInitialized() {
    if (!_initializedCompleter.isCompleted) {
      throw Exception(
          "Channel ${this.cid} hasn't been initialized yet. Make sure to call .watch() or to instantiate the client using [Channel.fromState]");
    }
  }
}

/// The class that handles the state of the channel listening to the events
class ChannelClientState {
  /// Creates a new instance listening to events and updating the state
  ChannelClientState(this._channel, ChannelState channelState) {
    _channelStateController = BehaviorSubject.seeded(channelState);
    _listenTypingEvents();

    _listenMessageNew();

    _listenMessageDeleted();

    _listenMessageUpdated();

    _listenReactionNew();

    _listenReactionDeleted();

    _listenReadEvents();

    _channel._client.offlineStorage
        ?.getChannelThreads(_channel.cid)
        ?.then((threads) {
      _threads = threads;
      retryFailedMessages();
    });
  }

  /// Retry failed message
  Future<void> retryFailedMessages() {
    final failedMessages = <Message>[
      ...messages,
      ...threads.values.expand((v) => v.reversed)
    ]
        .where((message) =>
            message.status != null &&
            message.status != MessageSendingStatus.SENT)
        .toList()
        .reversed;
    return Future.wait(failedMessages.map((message) {
      final List<Future> futures = [];
      if (message.status == MessageSendingStatus.FAILED_UPDATE ||
          message.status == MessageSendingStatus.UPDATING) {
        futures.add(_channel._client.updateMessage(
          message,
          _channel.cid,
        ));
      } else if (message.status == MessageSendingStatus.FAILED ||
          message.status == MessageSendingStatus.SENDING) {
        futures.add(_channel.sendMessage(
          message,
        ));
      } else if (message.status == MessageSendingStatus.FAILED_DELETE ||
          message.status == MessageSendingStatus.DELETING) {
        futures.add(_channel._client.deleteMessage(
          message,
          _channel.cid,
        ));
      }

      return futures;
    }).expand((v) => v));
  }

  void _listenReactionDeleted() {
    _channel.on(EventType.reactionDeleted).listen((event) {
      if (event.message.parentId == null ||
          event.message.showInChannel == true) {
        _channelState = this._channelState.copyWith(
              messages: this._channelState.messages.map((message) {
                if (message.id == event.message.id) {
                  return _removeReactionFromMessage(message, event);
                }
                return message;
              }).toList(),
            );
      }

      if (event.message.parentId != null) {
        final newThreads = threads;
        if (newThreads.containsKey(event.message.parentId)) {
          newThreads[event.message.parentId] =
              newThreads[event.message.parentId].map((message) {
            if (message.id == event.message.id) {
              return _removeReactionFromMessage(message, event);
            }
            return message;
          }).toList();
          _threads = newThreads;
        }
      }
    });
  }

  void _listenReactionNew() {
    _channel.on(EventType.reactionNew).listen((event) {
      if (event.message.parentId == null ||
          event.message.showInChannel == true) {
        _channelState = this._channelState.copyWith(
              messages: this._channelState.messages.map((message) {
                if (message.id == event.message.id) {
                  return _addReactionToMessage(message, event);
                }
                return message;
              }).toList(),
            );
      }

      if (event.message.parentId != null) {
        final newThreads = threads;
        if (newThreads.containsKey(event.message.parentId)) {
          newThreads[event.message.parentId] =
              newThreads[event.message.parentId].map((message) {
            if (message.id == event.message.id) {
              return _addReactionToMessage(message, event);
            }
            return message;
          }).toList();
          _threads = newThreads;
        }
      }
    });
  }

  void _listenMessageUpdated() {
    _channel.on(EventType.messageUpdated).listen((event) {
      if (event.message.parentId == null ||
          event.message.showInChannel == true) {
        _channelState = this._channelState.copyWith(
              messages: this._channelState.messages.map((message) {
                if (message.id == event.message.id) {
                  return event.message;
                }

                return message;
              }).toList(),
            );
      }

      if (event.message.parentId != null) {
        final newThreads = Map<String, List<Message>>.from(threads);
        if (newThreads.containsKey(event.message.parentId)) {
          newThreads[event.message.parentId] =
              newThreads[event.message.parentId].map((message) {
            if (message.id == event.message.id) {
              return event.message;
            }

            return message;
          }).toList();
          _threads = newThreads;
        }
      }
    });
  }

  void _listenMessageDeleted() {
    _channel.on(EventType.messageDeleted).listen((event) {
      if (event.message.parentId == null ||
          event.message.showInChannel == true) {
        _channelState = this._channelState.copyWith(
              messages: this._channelState.messages.map((message) {
                if (message.id == event.message.id) {
                  return event.message;
                }

                return message;
              }).toList(),
            );
      }

      if (event.message.parentId != null) {
        final newThreads = Map<String, List<Message>>.from(threads);
        if (newThreads.containsKey(event.message.parentId)) {
          newThreads[event.message.parentId] =
              newThreads[event.message.parentId].map((message) {
            if (message.id == event.message.id) {
              return event.message;
            }

            return message;
          }).toList();
          _threads = newThreads;
        }
      }
    });
  }

  void _listenMessageNew() {
    _channel.on(EventType.messageNew).listen((event) {
      if (event.message.parentId == null ||
          event.message.showInChannel == true) {
        final newMessages = List<Message>.from(this._channelState.messages);

        final oldIndex =
            newMessages.indexWhere((m) => m.id == event.message.id);
        if (oldIndex != -1) {
          newMessages[oldIndex] = event.message;
        } else {
          newMessages.add(event.message);
        }

        _channelState = this._channelState.copyWith(
              messages: newMessages,
              channel: this._channelState.channel.copyWith(
                    lastMessageAt: event.message.createdAt,
                  ),
            );
      }

      if (event.message.parentId != null) {
        updateThreadInfo(event.message.parentId, [event.message]);
      }
    });
  }

  void _listenReadEvents() {
    if (_channel.config?.readEvents == false) {
      return;
    }

    _channel
        .on(EventType.messageRead)
        .where((e) => e.user.id == _channel.client.state.user.id)
        .listen((event) {
      final read = this._channelState.read;
      final userReadIndex =
          read?.indexWhere((r) => r.user.id == _channel.client.state.user.id);

      if (userReadIndex != null && userReadIndex != -1) {
        final userRead = read.removeAt(userReadIndex);
        read.add(Read(user: userRead.user, lastRead: event.createdAt));
        _channelState = this._channelState.copyWith(read: read);
      }
    });
  }

  Message _addReactionToMessage(Message message, Event event) {
    final newMessage = message.copyWith(
      latestReactions: message.latestReactions..add(event.reaction),
      reactionCounts: (message.reactionCounts ?? {})
        ..addAll({
          event.reaction.type: (message.reactionCounts == null
                  ? 0
                  : message.reactionCounts[event.reaction.type] ?? 0) +
              1,
        }),
    );

    if (event.user.id == this._channel.client.state.user.id) {
      return newMessage.copyWith(
        ownReactions: message.ownReactions..add(event.reaction),
      );
    }

    return newMessage;
  }

  Message _removeReactionFromMessage(Message message, Event event) {
    final newMessage = message.copyWith(
      latestReactions: message.latestReactions
        ..removeWhere((r) => r.type == event.reaction.type),
      reactionCounts: message.reactionCounts
        ..addAll({
          event.reaction.type:
              (message.reactionCounts[event.reaction.type]) - 1,
        }),
    );

    newMessage.reactionCounts.removeWhere((_, v) => v == 0);

    if (event.user.id == this._channel.client.state.user.id) {
      return newMessage.copyWith(
        ownReactions: message.ownReactions
          ..removeWhere((r) => r.type == event.reaction.type),
      );
    }

    return newMessage;
  }

  /// Channel message list
  List<Message> get messages => _channelState.messages;

  /// Channel message list as a stream
  Stream<List<Message>> get messagesStream =>
      channelStateStream.map((cs) => cs.messages);

  /// Channel members list
  List<Member> get members => _channelState.members;

  /// Channel members list as a stream
  Stream<List<Member>> get membersStream =>
      channelStateStream.map((cs) => cs.members);

  /// Channel watcher count
  int get watcherCount => _channelState.watcherCount;

  /// Channel watcher count as a stream
  Stream<int> get watcherCountStream =>
      channelStateStream.map((cs) => cs.watcherCount);

  /// Channel watchers list
  List<User> get watchers => _channelState.watchers;

  /// Channel watchers list as a stream
  Stream<List<User>> get watchersStream =>
      channelStateStream.map((cs) => cs.watchers);

  /// Channel read list
  List<Read> get read => _channelState.read;

  /// Channel read list as a stream
  Stream<List<Read>> get readStream => channelStateStream.map((cs) => cs.read);

  /// Unread count getter
  int get unreadCount {
    final userId = _channel.client.state?.user?.id;
    final userRead = _channelState.read?.firstWhere(
      (read) => read.user.id == userId,
      orElse: () => null,
    );
    if (userRead == null) {
      return _channelState.messages?.length ?? 0;
    } else {
      return _channelState.messages.fold<int>(0, (count, message) {
        if (message.user.id != userId &&
            message.createdAt.isAfter(userRead.lastRead)) {
          return count + 1;
        }
        return count;
      });
    }
  }

  /// Update threads with updated information about messages
  void updateThreadInfo(String parentId, List<Message> messages) {
    final newThreads = Map<String, List<Message>>.from(threads);

    if (newThreads.containsKey(parentId)) {
      newThreads[parentId] = [
        ...newThreads[parentId]
                ?.where(
                    (newMessage) => !messages.any((m) => m.id == newMessage.id))
                ?.toList() ??
            [],
        ...messages,
      ];

      newThreads[parentId].sort(_sortByCreatedAt);
    } else {
      newThreads[parentId] = messages;
    }

    _threads = newThreads;
  }

  /// Update channelState with updated information
  void updateChannelState(ChannelState updatedState) {
    List<Message> newMessages = [
      ...updatedState?.messages ?? [],
      ..._channelState?.messages
              ?.where((m) =>
                  updatedState.messages
                      ?.any((newMessage) => newMessage.id == m.id) ==
                  false)
              ?.toList() ??
          [],
    ];

    newMessages.sort(_sortByCreatedAt);

    List<User> newWatchers = [
      ...updatedState?.watchers ?? [],
      ..._channelState?.watchers
              ?.where((w) =>
                  updatedState.watchers
                      ?.any((newWatcher) => newWatcher.id == w.id) ==
                  false)
              ?.toList() ??
          [],
    ];

    List<Member> newMembers = [
      ...updatedState?.members ?? [],
      ..._channelState?.members
              ?.where((m) =>
                  updatedState.members
                      ?.any((newMember) => newMember.userId == m.userId) ==
                  false)
              ?.toList() ??
          [],
    ];

    List<Read> newReads = [
      ...updatedState?.read ?? [],
      ..._channelState?.read
              ?.where((r) =>
                  updatedState.read
                      ?.any((newRead) => newRead.user.id == r.user.id) ==
                  false)
              ?.toList() ??
          [],
    ];

    _channelState = _channelState.copyWith(
      messages: newMessages,
      channel: _channelState.channel?.copyWith(
        lastMessageAt: updatedState.channel?.lastMessageAt,
        members: updatedState.channel?.members,
        createdAt: updatedState.channel?.createdAt,
        type: updatedState.channel?.type,
        extraData: updatedState.channel?.extraData,
        updatedAt: updatedState.channel?.updatedAt,
        id: updatedState.channel?.id,
        createdBy: updatedState.channel?.createdBy,
        config: updatedState.channel?.config,
        deletedAt: updatedState.channel?.deletedAt,
        cid: updatedState.channel?.cid,
        frozen: updatedState.channel?.frozen,
        memberCount: updatedState.channel?.memberCount,
      ),
      watchers: newWatchers,
      watcherCount: updatedState.watcherCount,
      members: newMembers,
      read: newReads,
    );
  }

  int _sortByCreatedAt(a, b) {
    if (a.createdAt == null) {
      return 1;
    }

    if (b.createdAt == null) {
      return -1;
    }

    return a.createdAt.compareTo(b.createdAt);
  }

  /// The channel state related to this client
  ChannelState get _channelState => _channelStateController.value;

  /// The channel state related to this client as a stream
  Stream<ChannelState> get channelStateStream => _channelStateController.stream;

  /// The channel state related to this client
  ChannelState get channelState => _channelStateController.value;
  BehaviorSubject<ChannelState> _channelStateController;

  set _channelState(v) {
    _channelStateController.add(v);
    _channel._client.offlineStorage?.updateChannelState(v);
  }

  /// The channel threads related to this channel
  Map<String, List<Message>> get threads => _threadsController.value;

  /// The channel threads related to this channel as a stream
  Stream<Map<String, List<Message>>> get threadsStream =>
      _threadsController.stream;
  BehaviorSubject<Map<String, List<Message>>> _threadsController =
      BehaviorSubject.seeded({});

  set _threads(Map<String, List<Message>> v) {
    _channel._client.offlineStorage?.updateMessages(
      v.values.expand((v) => v).toList(),
      _channel.cid,
    );
    _threadsController.add(v);
  }

  /// Channel related typing users last value
  List<User> get typingEvents => _typingEventsController.value;

  /// Channel related typing users stream
  Stream<List<User>> get typingEventsStream => _typingEventsController.stream;
  BehaviorSubject<List<User>> _typingEventsController =
      BehaviorSubject.seeded([]);

  final Channel _channel;
  final Map<User, DateTime> _typings = {};

  void _listenTypingEvents() {
    if (_channel.config?.typingEvents == false) {
      return;
    }

    this._channel.on(EventType.typingStart).listen((event) {
      if (event.user.id != _channel.client.state.user.id) {
        _typings[event.user] = DateTime.now();
        _typingEventsController.add(_typings.keys.toList());
      }
    });

    this._channel.on(EventType.typingStop).listen((event) {
      if (event.user.id != _channel.client.state.user.id) {
        _typings.remove(event.user);
        _typingEventsController.add(_typings.keys.toList());
      }
    });
  }

  void _clean() {
    final now = DateTime.now();
    _typings.forEach((user, lastTypingEvent) {
      if (now.difference(lastTypingEvent).inSeconds > 7) {
        this._channel.client.handleEvent(
              Event(
                type: EventType.typingStop,
                user: user,
                cid: _channel.cid,
              ),
            );
      }
    });
    _typingEventsController.add(_typings.keys.toList());
  }

  /// Call this method to dispose this object
  void dispose() {
    _channelStateController.close();
    _threadsController.close();
    _typingEventsController.close();
  }
}
