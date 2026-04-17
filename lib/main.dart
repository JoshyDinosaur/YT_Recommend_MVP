import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:googleapis/youtube/v3.dart';
import 'dart:async';

void main() => runApp(const MaterialApp(home: YTMvp()));

class VideoNode {
  VideoNode({
    required this.id,
    required this.title,
    this.thumbnailUrl,
    this.score = 0,
  });

  final String id;
  final String title;
  final String? thumbnailUrl;

  /// For neighbors: how many distinct liked videos linked here.
  int score;
}

class CoWatchGraph {
  final Map<String, VideoNode> liked = {};
  final Map<String, VideoNode> neighbors = {};
  final Map<String, Set<String>> _edgesFromLiked = {};

  void addLiked(VideoNode node) {
    liked[node.id] = node;
    _edgesFromLiked.putIfAbsent(node.id, () => <String>{});
  }

  /// One edge per (likedVideoId -> neighborId). Bumps neighbor [score] when a new liked source links to that neighbor.
  void addEdge(String likedVideoId, VideoNode neighbor) {
    _edgesFromLiked.putIfAbsent(likedVideoId, () => <String>{});
    final seen = _edgesFromLiked[likedVideoId]!;
    if (seen.contains(neighbor.id)) return;
    seen.add(neighbor.id);

    final existing = neighbors[neighbor.id];
    if (existing == null) {
      neighbor.score = 1;
      neighbors[neighbor.id] = neighbor;
    } else {
      existing.score++;
    }
  }

  /// Highest [score] first; optional: drop videos that are still in [liked].
  List<VideoNode> rankedNeighbors({bool excludeLiked = true}) {
    final list = neighbors.values.toList();
    if (excludeLiked) {
      list.removeWhere((n) => liked.containsKey(n.id));
    }
    list.sort((a, b) => b.score.compareTo(a.score));
    return list;
  }
}

class YTMvp extends StatefulWidget {
  const YTMvp({super.key});

  @override
  State<YTMvp> createState() => _YTMvpState();
}

class _YTMvpState extends State<YTMvp> {
  // Define scope from setup in Google Cloud
  final GoogleSignIn _googleSignIn = GoogleSignIn.instance;
  static const _ytScope = YouTubeApi.youtubeReadonlyScope;
  static const _ytScopes = [_ytScope];
  GoogleSignInAccount? _currentUser;
  List<VideoNode> _likedNodes = [];
  List<VideoNode> _rankedNeighbors = [];
  StreamSubscription<GoogleSignInAuthenticationEvent>? _authSub;

  @override
  void initState() {
    super.initState();
    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    unawaited(_authSub?.cancel());
    super.dispose();
  }

  Future<void> _bootstrap() async {
    await _googleSignIn.initialize();
    _authSub = _googleSignIn.authenticationEvents.listen((event) {
      if (!mounted) return;
      if (event is GoogleSignInAuthenticationEventSignIn) {
        setState(() => _currentUser = event.user);
      } else if (event is GoogleSignInAuthenticationEventSignOut) {
        setState(() => _currentUser = null);
      }
    });
    _googleSignIn.attemptLightweightAuthentication();
  }

  Future<void> _handleSignIn() async {
    try {
      final account = await _googleSignIn.authenticate(
        scopeHint: _ytScopes,
      ); //assign account the authenticated googleSignInAccount
      final yt = await _youTubeApiFor(
        account,
      ); //assign yt a dedicated youTube api caller
      final ch = await yt.channels.list(
        ['snippet'],
        mine: true,
      ); //assing ch the API call response of 'channels' grabbing 'snippet'
      final title = ch.items?.firstOrNull?.snippet?.title ?? '(no channel)';
      if (!mounted) return;
      setState(() => _currentUser = account);
      debugPrint('YouTube OK, channel: $title');
      final likedNodes = await _fetchLikedVideoNodes(yt);
      final graph = CoWatchGraph();
      for (final n in likedNodes) {
        graph.addLiked(n);
      }
      for (final liked in likedNodes) {
        final related = await _fetchRelatedForVideo(yt, liked.id, max: 8);
        for (final neighbor in related) {
          graph.addEdge(liked.id, neighbor);
        }
      }

      final ranked = graph.rankedNeighbors();
      debugPrint(
        'Graph: ${graph.liked.length} liked, ${graph.neighbors.length} neighbors, top: ${ranked.take(3).map((v) => "${v.title} (${v.score})").join(",")}',
      );
      setState(() {
        _likedNodes = likedNodes;
        _rankedNeighbors = ranked;
      });
    } on GoogleSignInException catch (e) {
      debugPrint("Sign-in: ${e.description}");
    } catch (e, st) {
      debugPrint('Login error: $e\n$st');
    }
  }

  Future<void> _handleSignOut() async {
    try {
      await _googleSignIn.signOut();
      if (!mounted) return;
      setState(() {
        _likedNodes = [];
        _rankedNeighbors = [];
      });
    } catch (e, st) {
      debugPrint('Sign out error: $e\n$st');
    }
  }

  Future<YouTubeApi> _youTubeApiFor(GoogleSignInAccount account) async {
    final auth = await account.authorizationClient.authorizeScopes(
      _ytScopes,
    ); //get accessTokens for required scopes
    return YouTubeApi(
      auth.authClient(scopes: _ytScopes),
    ); //call youTube apis with the accessTokens -- YouTubeApi is an API caller, all its properties are API method calls
  }

  Future<String?> _likesPlaylistId(YouTubeApi api) async {
    final res = await api.channels.list(['contentDetails'], mine: true);
    final items = res.items;
    if (items == null || items.isEmpty) return null;
    return items.first.contentDetails?.relatedPlaylists?.likes;
  }

  Future<List<VideoNode>> _fetchLikedVideoNodes(
    YouTubeApi api, {
    int max = 15,
  }) async {
    final playlistId = await _likesPlaylistId(api);
    if (playlistId == null) return [];

    final out = <VideoNode>[];
    String? pageToken;

    while (out.length < max) {
      final page = await api.playlistItems.list(
        ['snippet', 'contentDetails'],
        playlistId: playlistId,
        maxResults: 50,
        pageToken: pageToken,
      );

      for (final item in page.items ?? const <PlaylistItem>[]) {
        final id =
            item.contentDetails?.videoId ?? item.snippet?.resourceId?.videoId;
        if (id == null) continue;
        final title = item.snippet?.title ?? id;
        final thumb =
            item.snippet?.thumbnails?.medium?.url ??
            item.snippet?.thumbnails?.default_?.url;
        out.add(VideoNode(id: id, title: title, thumbnailUrl: thumb));
        if (out.length >= max) break;
      }

      pageToken = page.nextPageToken;
      if (pageToken == null) break;
    }
    return out;
  }

  Future<List<VideoNode>> _fetchRelatedForVideo(
    YouTubeApi api,
    String videoId, {
    int max = 10,
  }) async {
    final res = await api.search.list(
      ['snippet'],
      q: videoId,
      type: ['video'],
      maxResults: max,
    );

    final out = <VideoNode>[];
    for (final item in res.items ?? const <SearchResult>[]) {
      final id = item.id?.videoId;
      if (id == null) continue;

      final sn = item.snippet;
      out.add(
        VideoNode(
          id: id,
          title: sn?.title ?? id,
          thumbnailUrl:
              sn?.thumbnails?.medium?.url ?? sn?.thumbnails?.default_?.url,
        ),
      );
    }
    return out;
  }

  Widget _buildVideoList(
    List<VideoNode> nodes,
    String emptyMessage, {
    bool showScore = false,
  }) {
    if (nodes.isEmpty) {
      return Center(child: Text(emptyMessage));
    }
    return ListView.builder(
      itemCount: nodes.length,
      itemBuilder: (context, i) {
        final v = nodes[i];
        final thumb = v.thumbnailUrl;
        return ListTile(
          leading: thumb != null
              ? Image.network(thumb, width: 80, fit: BoxFit.cover)
              : const SizedBox(width: 80, child: Icon(Icons.movie)),
          title: Text(v.title, maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: Text(showScore ? '${v.id} · score ${v.score}' : v.id),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("YT Recommend MVP")),
      body: Center(
        child: _currentUser == null
            ? ElevatedButton(
                onPressed: _handleSignIn,
                child: Text("Login with Google"),
              )
            : DefaultTabController(
                length: 2,
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Signed in',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          OutlinedButton(
                            onPressed: _handleSignOut,
                            child: const Text('Sign out'),
                          ),
                        ],
                      ),
                    ),
                    TabBar(
                      tabs: [
                        Tab(text: 'Liked (${_likedNodes.length})'),
                        Tab(text: 'Recommended (${_rankedNeighbors.length})'),
                      ],
                    ),
                    Expanded(
                      child: TabBarView(
                        children: [
                          _buildVideoList(
                            _likedNodes,
                            'No liked videos loaded yet.',
                          ),
                          _buildVideoList(
                            _rankedNeighbors,
                            'No recommendations yet. Sign in again to refresh.',
                            showScore: true,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}
