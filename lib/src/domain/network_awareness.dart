/// Supplies the application's current connection state for retry decisions.
/// Return true to allow a retry or false to stop after a failed request.
abstract interface class NetworkAwareness {
  Future<bool> get isConnected;
}
