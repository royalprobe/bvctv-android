// Stub for non-Android platforms
class AndroidWebViewController {
  void setMediaPlaybackRequiresUserGesture(bool requires) {}
}

class AndroidWebViewWidgetCreationParams {
  const AndroidWebViewWidgetCreationParams({
    required dynamic controller,
    this.displayWithHybridComposition = false,
    this.gestureRecognizers,
  });
  final bool displayWithHybridComposition;
  final Set<dynamic>? gestureRecognizers;
}
