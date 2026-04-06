import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:googleapis/youtube/v3.dart';

void main() => runApp(MaterialApp(home: YTMvp()));

class YTMvp extends StatefulWidget {
  @override
  _YTMvpState createState() => _YTMvpState();
  // TODO start here with understanding the stateful widget setup for the login screen
}
