import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'robot_profile.dart';

/// Persists the robot profile on the tablet.
class ProfileStore {
  static const _key = 'robot_profile_v1';

  Future<RobotProfile> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return RobotProfile.defaults();
    try {
      return RobotProfile.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on Object {
      return RobotProfile.defaults();
    }
  }

  Future<void> save(RobotProfile profile) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(profile.toJson()));
  }
}
