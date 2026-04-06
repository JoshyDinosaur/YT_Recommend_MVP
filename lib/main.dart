import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:googleapis/youtube/v3.dart';

void main() => runApp(MaterialApp(home: YTMvp()));

class YTMvp extends StatefulWidget {
  @override
  _YTMvpState createState() => _YTMvpState();
}

class _YTMvpState extends State<YTMvp> {
  // Define scope from setup in Google Cloud
  final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: [YouTubeApi.youtubeReadonlyScope],
  );

  GoogleSignInAccount? _currentUser;

  @override
  void initState() {
    super.initState();
    _googleSignIn.onCurrentUserChanged.listen((account) {
      setState(() => _currentUser = account);
    });
    // TODO.. start here after Stream subscription
  }
}
