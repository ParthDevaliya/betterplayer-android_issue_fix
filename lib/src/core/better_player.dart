import 'dart:async';
import 'package:better_player/better_player.dart';
import 'package:better_player/src/configuration/better_player_controller_event.dart';
import 'package:better_player/src/core/better_player_utils.dart';
import 'package:better_player/src/core/better_player_with_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// Widget which uses provided controller to render video player.
class BetterPlayer extends StatefulWidget {
  const BetterPlayer({Key? key, required this.controller}) : super(key: key);

  factory BetterPlayer.network(
    String url, {
    BetterPlayerConfiguration? betterPlayerConfiguration,
  }) =>
      BetterPlayer(
        controller: BetterPlayerController(
          betterPlayerConfiguration ?? const BetterPlayerConfiguration(),
          betterPlayerDataSource: BetterPlayerDataSource(BetterPlayerDataSourceType.network, url),
        ),
      );

  factory BetterPlayer.file(
    String url, {
    BetterPlayerConfiguration? betterPlayerConfiguration,
  }) =>
      BetterPlayer(
        controller: BetterPlayerController(
          betterPlayerConfiguration ?? const BetterPlayerConfiguration(),
          betterPlayerDataSource: BetterPlayerDataSource(BetterPlayerDataSourceType.file, url),
        ),
      );

  final BetterPlayerController controller;

  @override
  _BetterPlayerState createState() {
    return _BetterPlayerState();
  }
}

class _BetterPlayerState extends State<BetterPlayer> with WidgetsBindingObserver {
  BetterPlayerConfiguration get _betterPlayerConfiguration => widget.controller.betterPlayerConfiguration;

  bool _isFullScreen = false;
  late NavigatorState _navigatorState;
  bool _initialized = false;
  StreamSubscription? _controllerEventSubscription;
  Duration? _lastPosition;
  double? _savedVolume;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    if (!_initialized) {
      _navigatorState = Navigator.of(context);
      _setup();
      _initialized = true;
    }
    super.didChangeDependencies();
  }

  Future<void> _setup() async {
    _controllerEventSubscription = widget.controller.controllerEventStream.listen(onControllerEvent);
    var locale = const Locale("en", "US");
    try {
      if (mounted) {
        locale = Localizations.localeOf(context);
      }
    } catch (exception) {
      BetterPlayerUtils.log(exception.toString());
    }
    widget.controller.setupTranslations(locale);
  }

  @override
  void dispose() {
    if (_isFullScreen) {
      WakelockPlus.disable();
      _navigatorState.maybePop();
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: _betterPlayerConfiguration.systemOverlaysAfterFullScreen);
      SystemChrome.setPreferredOrientations(_betterPlayerConfiguration.deviceOrientationsAfterFullScreen);
    }

    WidgetsBinding.instance.removeObserver(this);
    _controllerEventSubscription?.cancel();
    widget.controller.dispose();
    VisibilityDetectorController.instance.forget(Key("${widget.controller.hashCode}_key"));
    super.dispose();
  }

  @override
  void didUpdateWidget(BetterPlayer oldWidget) {
    if (oldWidget.controller != widget.controller) {
      _controllerEventSubscription = widget.controller.controllerEventStream.listen(onControllerEvent);
    }
    super.didUpdateWidget(oldWidget);
  }

  void onControllerEvent(BetterPlayerControllerEvent event) {
    switch (event) {
      case BetterPlayerControllerEvent.openFullscreen:
        onFullScreenChanged();
        break;
      case BetterPlayerControllerEvent.hideFullscreen:
        onFullScreenChanged();
        break;
      default:
        setState(() {});
        break;
    }
  }

  Future<void> onFullScreenChanged() async {
    final controller = widget.controller;

    if (controller.isFullScreen && !_isFullScreen) {
      _isFullScreen = true;
      _lastPosition = controller.videoPlayerController?.value.position;
      final wasPlaying = controller.isPlaying();

      controller.postEvent(BetterPlayerEvent(BetterPlayerEventType.openFullscreen));
      await _pushFullScreenWidget(context);

      if (_lastPosition != null) {
        await controller.seekTo(_lastPosition!);
      }
      if (wasPlaying) {
        controller.play();
      }
    } else if (_isFullScreen) {
      Navigator.of(context, rootNavigator: true).pop();
      _isFullScreen = false;
      controller.postEvent(BetterPlayerEvent(BetterPlayerEventType.hideFullscreen));
    }
  }

  @override
  Widget build(BuildContext context) {
    return BetterPlayerControllerProvider(
      controller: widget.controller,
      child: _buildPlayer(),
    );
  }

  Widget _buildFullScreenVideo(BuildContext context, Animation<double> animation, BetterPlayerControllerProvider controllerProvider) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: Container(
        alignment: Alignment.center,
        color: Colors.black,
        child: controllerProvider,
      ),
    );
  }

  AnimatedWidget _defaultRoutePageBuilder(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation, BetterPlayerControllerProvider controllerProvider) {
    return AnimatedBuilder(
      animation: animation,
      builder: (BuildContext context, Widget? child) {
        return _buildFullScreenVideo(context, animation, controllerProvider);
      },
    );
  }

  Widget _fullScreenRoutePageBuilder(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final controllerProvider = BetterPlayerControllerProvider(controller: widget.controller, child: _buildPlayer());
    final routePageBuilder = _betterPlayerConfiguration.routePageBuilder;
    if (routePageBuilder == null) {
      return _defaultRoutePageBuilder(context, animation, secondaryAnimation, controllerProvider);
    }

    return routePageBuilder(context, animation, secondaryAnimation, controllerProvider);
  }

  Future<dynamic> _pushFullScreenWidget(BuildContext context) async {
    final TransitionRoute<void> route = PageRouteBuilder<void>(
      settings: const RouteSettings(),
      pageBuilder: _fullScreenRoutePageBuilder,
    );

    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    if (_betterPlayerConfiguration.autoDetectFullscreenDeviceOrientation == true) {
      final aspectRatio = widget.controller.videoPlayerController?.value.aspectRatio ?? 1.0;
      List<DeviceOrientation> deviceOrientations;
      if (aspectRatio < 1.0) {
        deviceOrientations = [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown];
      } else {
        deviceOrientations = [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight];
      }
      await SystemChrome.setPreferredOrientations(deviceOrientations);
    } else {
      await SystemChrome.setPreferredOrientations(
        widget.controller.betterPlayerConfiguration.deviceOrientationsOnFullScreen,
      );
    }

    if (!_betterPlayerConfiguration.allowedScreenSleep) {
      WakelockPlus.enable();
    }

    await Navigator.of(context, rootNavigator: true).push(route);
    _isFullScreen = false;
    widget.controller.exitFullScreen();
    WakelockPlus.disable();
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: _betterPlayerConfiguration.systemOverlaysAfterFullScreen);
    await SystemChrome.setPreferredOrientations(_betterPlayerConfiguration.deviceOrientationsAfterFullScreen);
  }

  Widget _buildPlayer() {
    return VisibilityDetector(
      key: Key("${widget.controller.hashCode}_key"),
      onVisibilityChanged: (VisibilityInfo info) => widget.controller.onPlayerVisibilityChanged(info.visibleFraction),
      child: BetterPlayerWithControls(
        controller: widget.controller,
      ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.paused) {
      _savedVolume = widget.controller.videoPlayerController?.value.volume;
      widget.controller.setVolume(0.0);
    } else if (state == AppLifecycleState.resumed && _savedVolume != null) {
      widget.controller.setVolume(_savedVolume!);
    }
    widget.controller.setAppLifecycleState(state);
  }
}
