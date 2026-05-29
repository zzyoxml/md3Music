import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models/song.dart';
import '../../providers/player_provider.dart';

class PlayerController extends StatelessWidget {
  final Widget child;

  const PlayerController({
    super.key,
    required this.child,
  });

  static PlayerProvider of(BuildContext context) {
    return context.read<PlayerProvider>();
  }

  static PlayerProvider watch(BuildContext context) {
    return context.watch<PlayerProvider>();
  }

  static void playSong(BuildContext context, Song song) {
    context.read<PlayerProvider>().playSong(song);
  }

  static void playPlaylist(BuildContext context, List<Song> songs, int startIndex) {
    context.read<PlayerProvider>().playPlaylist(songs, startIndex);
  }

  static void togglePlayPause(BuildContext context) {
    final provider = context.read<PlayerProvider>();
    if (provider.isPlaying) {
      provider.pause();
    } else {
      provider.resume();
    }
  }

  static void next(BuildContext context) {
    context.read<PlayerProvider>().next();
  }

  static void previous(BuildContext context) {
    context.read<PlayerProvider>().previous();
  }

  static void seek(BuildContext context, Duration position) {
    context.read<PlayerProvider>().seek(position);
  }

  static void toggleShuffle(BuildContext context) {
    context.read<PlayerProvider>().toggleShuffle();
  }

  static void toggleLoopMode(BuildContext context) {
    context.read<PlayerProvider>().toggleLoopMode();
  }

  static void setVolume(BuildContext context, double volume) {
    context.read<PlayerProvider>().setVolume(volume);
  }

  static void setSpeed(BuildContext context, double speed) {
    context.read<PlayerProvider>().setSpeed(speed);
  }

  static Song? currentSong(BuildContext context) {
    return context.watch<PlayerProvider>().currentSong;
  }

  static bool isPlaying(BuildContext context) {
    return context.watch<PlayerProvider>().isPlaying;
  }

  static Duration position(BuildContext context) {
    return context.watch<PlayerProvider>().position;
  }

  static Duration? duration(BuildContext context) {
    return context.watch<PlayerProvider>().duration;
  }

  static bool isCurrentSong(BuildContext context, Song song) {
    return context.watch<PlayerProvider>().currentSong?.id == song.id;
  }

  @override
  Widget build(BuildContext context) {
    return child;
  }
}
