import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:googleapis/youtube/v3.dart';
import 'package:google_fonts/google_fonts.dart';
import 'dart:async';

void main() => runApp(const MaterialApp(home: YTMvp()));

class VideoNode {
  VideoNode({
    required this.id,
    required this.title,
    this.thumbnailUrl,
    this.categoryId,
    this.tags,
    this.score = 0,
  });

  final String id;
  final String title;
  final String? thumbnailUrl;
  final String? categoryId;
  final List<String>? tags;

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
  void addEdge(
    String likedVideoId,
    VideoNode neighbor, {
    int scoreIncrement = 1,
  }) {
    _edgesFromLiked.putIfAbsent(likedVideoId, () => <String>{});
    final seen = _edgesFromLiked[likedVideoId]!;
    if (seen.contains(neighbor.id)) return;
    seen.add(neighbor.id);

    final existing = neighbors[neighbor.id];
    if (existing == null) {
      neighbor.score = scoreIncrement;
      neighbors[neighbor.id] = neighbor;
    } else {
      existing.score += scoreIncrement;
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
  static const int _maxSearchCallsPerSession = 3;
  static const Map<String, String> _ytCategoryNames = {
    '1': 'Film & Animation',
    '2': 'Autos & Vehicles',
    '10': 'Music',
    '15': 'Pets & Animals',
    '17': 'Sports',
    '19': 'Travel & Events',
    '20': 'Gaming',
    '22': 'People & Blogs',
    '23': 'Comedy',
    '24': 'Entertainment',
    '25': 'News & Politics',
    '26': 'Howto & Style',
    '27': 'Education',
    '28': 'Science & Technology',
    '29': 'Nonprofits & Activism',
  };
  GoogleSignInAccount? _currentUser;
  bool _showResults = false;
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

  Color _cardColorForCategory(String? categoryId) {
    const redTint = Color(0xFF2A1E1E);
    const blueTint = Color(0xFF1E1E2A);
    const greenTint = Color(0xFF1E2A1E);
    const neutral = Color(0xFF252525);

    switch (categoryId) {
      // Red - entertainment/arts
      case '1': // Film & Animation
      case '10': // Music
      case '22': // People & Blogs
      case '23': // Comedy
      case '24': // Entertainment
        return redTint;

      // Blue - knowledge
      case '25': // News & Politics
      case '27': // Education
      case '28': // Science & Technology
      case '29': // Nonprofits & Activism
        return blueTint;

      // Green - activity/lifestyle
      case '2': // Auto & Vechicles
      case '15': // Pets & Animals
      case '17': // Sports
      case '19': // Travel & Events
      case '20': // Gaming
      case '26': // Howto & Style
        return greenTint;

      default:
        return neutral;
    }
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
      final seedVideos = _pickDistinctCategorySeeds(
        likedNodes,
        maxSeeds: _maxSearchCallsPerSession,
      );
      debugPrint(
        'Seeds: ${seedVideos.map((v) {
          final catName = _ytCategoryNames[v.categoryId] ?? v.categoryId ?? "unknown";
          return '"${v.title}" cat:$catName';
        }).join(" | ")}',
      );

      for (final liked in seedVideos) {
        final related = await _fetchRelatedForVideo(yt, liked, max: 50);
        for (final neighbor in related) {
          final overlap = _tagWordOverlap(liked, neighbor);
          graph.addEdge(
            liked.id,
            neighbor,
            scoreIncrement: overlap > 0 ? overlap : 1,
          );
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

  Future<void> _handleGenerateEdges() async {
    try {
      GoogleSignInAccount? account = _currentUser;

      // if not signed in yet, trigger OAuth now
      if (account == null) {
        account = await _googleSignIn.authenticate(scopeHint: _ytScopes);
        if (!mounted) return;
        setState(() => _currentUser = account);
      }

      final yt = await _youTubeApiFor(account!);

      final likedNodes = await _fetchLikedVideoNodes(yt);
      final graph = CoWatchGraph();
      for (final n in likedNodes) {
        graph.addLiked(n);
      }

      final seedVideos = _pickDistinctCategorySeeds(
        likedNodes,
        maxSeeds: _maxSearchCallsPerSession,
      );
      debugPrint(
        'Seeds: ${seedVideos.map((v) {
          final catName = _ytCategoryNames[v.categoryId] ?? v.categoryId ?? "unknown";
          return '"${v.title}" cat:$catName';
        }).join(" | ")}',
      );

      for (final liked in seedVideos) {
        final related = await _fetchRelatedForVideo(yt, liked, max: 50);
        for (final neighbor in related) {
          final overlap = _tagWordOverlap(liked, neighbor);
          graph.addEdge(
            liked.id,
            neighbor,
            scoreIncrement: overlap > 0 ? overlap : 1,
          );
        }
      }

      final ranked = graph.rankedNeighbors();
      if (!mounted) return;
      setState(() {
        _likedNodes = likedNodes;
        _rankedNeighbors = ranked;
        _showResults = true;
      });
    } on GoogleSignInException catch (e) {
      debugPrint("Sign-in: ${e.description}");
    } catch (e, st) {
      debugPrint('Generate edges error: $e\n$st');
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
    return _attachCategories(api, out);
  }

  List<VideoNode> _pickDistinctCategorySeeds(
    List<VideoNode> likedNodes, {
    int maxSeeds = 3,
  }) {
    final picked = <VideoNode>[];
    final seenCategories = <String>{};

    for (final node in likedNodes) {
      final cat = node.categoryId;
      if (cat == null || cat.isEmpty) continue;
      if (seenCategories.add(cat)) {
        picked.add(node);
        if (picked.length >= maxSeeds) return picked;
      }
    }

    for (final node in likedNodes) {
      if (picked.any((p) => p.id == node.id)) continue;
      picked.add(node);
      if (picked.length >= maxSeeds) break;
    }

    return picked;
  }

  Future<List<VideoNode>> _attachCategories(
    YouTubeApi api,
    List<VideoNode> nodes,
  ) async {
    if (nodes.isEmpty) return nodes;

    final ids = nodes.map((n) => n.id).toList();
    final categoryById = <String, String?>{};
    final tagsById = <String, List<String>?>{};

    for (var i = 0; i < ids.length; i += 50) {
      final chunk = ids.sublist(i, (i + 50 > ids.length) ? ids.length : i + 50);
      final res = await api.videos.list(['snippet'], id: chunk);
      for (final v in res.items ?? const <Video>[]) {
        final vid = v.id;
        if (vid == null) continue;
        categoryById[vid] = v.snippet?.categoryId;
        tagsById[vid] = v.snippet?.tags;
      }
    }
    return nodes
        .map(
          (n) => VideoNode(
            id: n.id,
            title: n.title,
            thumbnailUrl: n.thumbnailUrl,
            categoryId: categoryById[n.id],
            tags: tagsById[n.id],
            score: n.score,
          ),
        )
        .toList();
  }

  String _searchQueryFromSeed(VideoNode seed) {
    final buf = StringBuffer();
    void appendWord(String w) {
      final t = w.trim();
      if (t.isEmpty) return;
      if (buf.isNotEmpty) buf.write(' ');
      buf.write(t);
    }

    for (final word in seed.title.split(RegExp(r'\s+'))) {
      appendWord(word);
      //appends each split word from the title to the buffer
    }
    final tagList = seed.tags;
    if (tagList != null) {
      for (final tag in tagList.take(5)) {
        appendWord(tag);
        //append each tag from the user upload to the buffer
      }
    }

    var q = buf.toString();
    if (q.length > 200) q = q.substring(0, 200).trim();
    if (q.isEmpty) {
      q = seed.title.trim().isNotEmpty ? seed.title.trim() : seed.id;
    }
    return q;
  }

  int _tagWordOverlap(VideoNode seed, VideoNode neighbor) {
    final seedTags = seed.tags;
    final neighborTags = neighbor.tags;
    if (seedTags == null || neighborTags == null) return 0;

    // build a set of lowecase words from all seed tags
    final seedWords = <String>{};
    for (final tag in seedTags) {
      for (final word in tag.toLowerCase().split(RegExp(r'[\s\-,]+'))) {
        if (word.length > 2)
          seedWords.add(word); // skip tiny 1 and 2 letter words
      }
    }

    // count how many words in neighbor tags appear in seedWords
    var count = 0;
    for (final tag in neighborTags) {
      for (final word in tag.toLowerCase().split(RegExp(r'[\s\-,]+'))) {
        if (word.length > 2 && seedWords.contains(word)) count++;
      }
    }
    return count;
  }

  Future<List<VideoNode>> _fetchRelatedForVideo(
    YouTubeApi api,
    VideoNode seed, {
    int max = 10,
  }) async {
    final q = _searchQueryFromSeed(seed);
    debugPrint('search q for "${seed.title}": $q');

    final res = await api.search.list(
      ['snippet'],
      q: q,
      type: ['video'],
      maxResults: max,
      relevanceLanguage: 'en',
      regionCode: 'US',
    );

    final out = <VideoNode>[];
    for (final item in res.items ?? const <SearchResult>[]) {
      final id = item.id?.videoId;
      if (id == null || id == seed.id) continue;

      final sn = item.snippet;
      final title = sn?.title ?? id;
      if (RegExp(r'[\u0400-\u04FF]').hasMatch(title)) continue;
      out.add(
        VideoNode(
          id: id,
          title: sn?.title ?? id,
          thumbnailUrl:
              sn?.thumbnails?.medium?.url ?? sn?.thumbnails?.default_?.url,
        ),
      );
    }
    if (out.isNotEmpty) {
      final ids = out.map((n) => n.id).toList();
      final tagsById = <String, List<String>?>{};
      final categoryById = <String, String?>{};
      for (int i = 0; i < ids.length; i += 50) {
        final chunk = ids.sublist(
          i,
          (i + 50 > ids.length) ? ids.length : i + 50,
        );
        final vRes = await api.videos.list(['snippet'], id: chunk);
        for (final v in vRes.items ?? const <Video>[]) {
          if (v.id != null) {
            tagsById[v.id!] = v.snippet?.tags;
            categoryById[v.id!] = v.snippet?.categoryId;
          }
        }
      }
      return out
          .map(
            (n) => VideoNode(
              id: n.id,
              title: n.title,
              thumbnailUrl: n.thumbnailUrl,
              tags: tagsById[n.id],
              categoryId: categoryById[n.id],
            ),
          )
          .toList();
    }
    return out;
  }

  Widget _buildVideoList(
    List<VideoNode> nodes,
    String emptyMessage, {
    bool showScore = false,
  }) {
    if (nodes.isEmpty) {
      return Center(
        child: Text(
          emptyMessage,
          style: const TextStyle(color: Colors.white54),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: nodes.length,
      itemBuilder: (context, i) {
        final v = nodes[i];
        final thumb = v.thumbnailUrl;
        final cardColor = _cardColorForCategory(v.categoryId);
        return Container(
          margin: const EdgeInsets.only(bottom: 10),
          decoration: BoxDecoration(
            color: cardColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white10, width: 0.5),
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: const BorderRadius.horizontal(
                  left: Radius.circular(12),
                ),
                child: thumb != null
                    ? Image.network(
                        thumb,
                        width: 120,
                        height: 72,
                        fit: BoxFit.cover,
                      )
                    : const SizedBox(
                        width: 120,
                        height: 72,
                        child: Icon(Icons.movie, color: Colors.white24),
                      ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        v.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (showScore) ...[
                        const SizedBox(height: 4),
                        Text(
                          'score ${v.score}',
                          style: const TextStyle(
                            color: Colors.white38,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildLandingPage() {
    return Scaffold(
      backgroundColor: const Color(0xFF1C1C1E),
      body: SafeArea(
        child: Column(
          children: [
            const Spacer(flex: 2),
            Center(
              child: Image.asset(
                'assets/images/LikePartite_1.png',
                height: 180,
                filterQuality: FilterQuality.high,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'LikePartite',
              style: GoogleFonts.montserrat(
                color: Colors.white,
                fontSize: 32,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.5,
              ),
            ),
            const Spacer(flex: 1),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 48),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2A1E1E),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                      side: const BorderSide(color: Colors.white24),
                    ),
                  ),
                  onPressed: _handleGenerateEdges,
                  child: Text(
                    'Generate Edges',
                    style: GoogleFonts.montserrat(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0.8,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 52),
          ],
        ),
      ),
    );
  }

  Widget _buildResultsView(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          TabBar(
            indicatorColor: Colors.white70,
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white38,
            tabs: [
              Tab(text: 'Liked (${_likedNodes.length})'),
              Tab(text: 'Recommended (${_rankedNeighbors.length})'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _buildVideoList(_likedNodes, 'No liked videos loaded yet.'),
                _buildVideoList(
                  _rankedNeighbors,
                  'No recommendations yet.',
                  showScore: true,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1C1C1E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1C1C1E),
        toolbarHeight: 72,
        title: SizedBox(
          height: 52,
          child: Image.asset(
            'assets/images/LikePartite_1.png',
            fit: BoxFit.contain,
            filterQuality: FilterQuality.high,
          ),
        ),
        centerTitle: true,
        actions: _currentUser != null
            ? [
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white70,
                      side: const BorderSide(color: Colors.white24),
                    ),
                    onPressed: _handleSignOut,
                    child: const Text('Sign out'),
                  ),
                ),
              ]
            : null,
      ),
      body: _showResults ? _buildResultsView(context) : _buildLandingPage(),
    );
  }
}
