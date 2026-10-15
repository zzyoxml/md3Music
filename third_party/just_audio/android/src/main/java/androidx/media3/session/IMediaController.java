/*
 * This file is auto-generated.  DO NOT MODIFY.
 */
package androidx.media3.session;
/**
 * Interface from MediaSession to MediaController.
 * 
 * <p>It's for internal use only, not intended to be used by library users.
 */
// Note: Keep this interface oneway. Otherwise a malicious app may make a blocking call to make
// controller frozen.
public interface IMediaController extends android.os.IInterface
{
  /** Default implementation for IMediaController. */
  public static class Default implements androidx.media3.session.IMediaController
  {
    // Id < 3000 is reserved to avoid potential collision with media2 1.x.
    @Override public void onConnected(int seq, android.os.Bundle connectionResult) throws android.os.RemoteException
    {
    }
    @Override public void onSessionResult(int seq, android.os.Bundle sessionResult) throws android.os.RemoteException
    {
    }
    @Override public void onLibraryResult(int seq, android.os.Bundle libraryResult) throws android.os.RemoteException
    {
    }
    @Override public void onSetCustomLayout(int seq, java.util.List<android.os.Bundle> commandButtonList) throws android.os.RemoteException
    {
    }
    @Override public void onCustomCommand(int seq, android.os.Bundle command, android.os.Bundle args) throws android.os.RemoteException
    {
    }
    @Override public void onDisconnected(int seq) throws android.os.RemoteException
    {
    }
    /** Deprecated: Use onPlayerInfoChangedWithExclusions from MediaControllerStub#VERSION_INT=2. */
    @Override public void onPlayerInfoChanged(int seq, android.os.Bundle playerInfoBundle, boolean isTimelineExcluded) throws android.os.RemoteException
    {
    }
    /** Introduced to deprecate onPlayerInfoChanged (from MediaControllerStub#VERSION_INT=2). */
    @Override public void onPlayerInfoChangedWithExclusions(int seq, android.os.Bundle playerInfoBundle, android.os.Bundle playerInfoExclusions) throws android.os.RemoteException
    {
    }
    @Override public void onPeriodicSessionPositionInfoChanged(int seq, android.os.Bundle sessionPositionInfo) throws android.os.RemoteException
    {
    }
    @Override public void onAvailableCommandsChangedFromPlayer(int seq, android.os.Bundle commandsBundle) throws android.os.RemoteException
    {
    }
    @Override public void onAvailableCommandsChangedFromSession(int seq, android.os.Bundle sessionCommandsBundle, android.os.Bundle playerCommandsBundle) throws android.os.RemoteException
    {
    }
    @Override public void onRenderedFirstFrame(int seq) throws android.os.RemoteException
    {
    }
    @Override public void onExtrasChanged(int seq, android.os.Bundle extras) throws android.os.RemoteException
    {
    }
    @Override public void onSessionActivityChanged(int seq, android.app.PendingIntent pendingIntent) throws android.os.RemoteException
    {
    }
    @Override public void onError(int seq, android.os.Bundle sessionError) throws android.os.RemoteException
    {
    }
    // Next Id for MediaController: 3015
    @Override public void onChildrenChanged(int seq, java.lang.String parentId, int itemCount, android.os.Bundle libraryParams) throws android.os.RemoteException
    {
    }
    @Override public void onSearchResultChanged(int seq, java.lang.String query, int itemCount, android.os.Bundle libraryParams) throws android.os.RemoteException
    {
    }
    @Override
    public android.os.IBinder asBinder() {
      return null;
    }
  }
  /** Local-side IPC implementation stub class. */
  public static abstract class Stub extends android.os.Binder implements androidx.media3.session.IMediaController
  {
    /** Construct the stub at attach it to the interface. */
    public Stub()
    {
      this.attachInterface(this, DESCRIPTOR);
    }
    /**
     * Cast an IBinder object into an androidx.media3.session.IMediaController interface,
     * generating a proxy if needed.
     */
    public static androidx.media3.session.IMediaController asInterface(android.os.IBinder obj)
    {
      if ((obj==null)) {
        return null;
      }
      android.os.IInterface iin = obj.queryLocalInterface(DESCRIPTOR);
      if (((iin!=null)&&(iin instanceof androidx.media3.session.IMediaController))) {
        return ((androidx.media3.session.IMediaController)iin);
      }
      return new androidx.media3.session.IMediaController.Stub.Proxy(obj);
    }
    @Override public android.os.IBinder asBinder()
    {
      return this;
    }
    @Override public boolean onTransact(int code, android.os.Parcel data, android.os.Parcel reply, int flags) throws android.os.RemoteException
    {
      java.lang.String descriptor = DESCRIPTOR;
      if (code >= android.os.IBinder.FIRST_CALL_TRANSACTION && code <= android.os.IBinder.LAST_CALL_TRANSACTION) {
        data.enforceInterface(descriptor);
      }
      switch (code)
      {
        case INTERFACE_TRANSACTION:
        {
          reply.writeString(descriptor);
          return true;
        }
      }
      switch (code)
      {
        case TRANSACTION_onConnected:
        {
          int _arg0;
          _arg0 = data.readInt();
          android.os.Bundle _arg1;
          _arg1 = _Parcel.readTypedObject(data, android.os.Bundle.CREATOR);
          this.onConnected(_arg0, _arg1);
          break;
        }
        case TRANSACTION_onSessionResult:
        {
          int _arg0;
          _arg0 = data.readInt();
          android.os.Bundle _arg1;
          _arg1 = _Parcel.readTypedObject(data, android.os.Bundle.CREATOR);
          this.onSessionResult(_arg0, _arg1);
          break;
        }
        case TRANSACTION_onLibraryResult:
        {
          int _arg0;
          _arg0 = data.readInt();
          android.os.Bundle _arg1;
          _arg1 = _Parcel.readTypedObject(data, android.os.Bundle.CREATOR);
          this.onLibraryResult(_arg0, _arg1);
          break;
        }
        case TRANSACTION_onSetCustomLayout:
        {
          int _arg0;
          _arg0 = data.readInt();
          java.util.List<android.os.Bundle> _arg1;
          _arg1 = data.createTypedArrayList(android.os.Bundle.CREATOR);
          this.onSetCustomLayout(_arg0, _arg1);
          break;
        }
        case TRANSACTION_onCustomCommand:
        {
          int _arg0;
          _arg0 = data.readInt();
          android.os.Bundle _arg1;
          _arg1 = _Parcel.readTypedObject(data, android.os.Bundle.CREATOR);
          android.os.Bundle _arg2;
          _arg2 = _Parcel.readTypedObject(data, android.os.Bundle.CREATOR);
          this.onCustomCommand(_arg0, _arg1, _arg2);
          break;
        }
        case TRANSACTION_onDisconnected:
        {
          int _arg0;
          _arg0 = data.readInt();
          this.onDisconnected(_arg0);
          break;
        }
        case TRANSACTION_onPlayerInfoChanged:
        {
          int _arg0;
          _arg0 = data.readInt();
          android.os.Bundle _arg1;
          _arg1 = _Parcel.readTypedObject(data, android.os.Bundle.CREATOR);
          boolean _arg2;
          _arg2 = (0!=data.readInt());
          this.onPlayerInfoChanged(_arg0, _arg1, _arg2);
          break;
        }
        case TRANSACTION_onPlayerInfoChangedWithExclusions:
        {
          int _arg0;
          _arg0 = data.readInt();
          android.os.Bundle _arg1;
          _arg1 = _Parcel.readTypedObject(data, android.os.Bundle.CREATOR);
          android.os.Bundle _arg2;
          _arg2 = _Parcel.readTypedObject(data, android.os.Bundle.CREATOR);
          this.onPlayerInfoChangedWithExclusions(_arg0, _arg1, _arg2);
          break;
        }
        case TRANSACTION_onPeriodicSessionPositionInfoChanged:
        {
          int _arg0;
          _arg0 = data.readInt();
          android.os.Bundle _arg1;
          _arg1 = _Parcel.readTypedObject(data, android.os.Bundle.CREATOR);
          this.onPeriodicSessionPositionInfoChanged(_arg0, _arg1);
          break;
        }
        case TRANSACTION_onAvailableCommandsChangedFromPlayer:
        {
          int _arg0;
          _arg0 = data.readInt();
          android.os.Bundle _arg1;
          _arg1 = _Parcel.readTypedObject(data, android.os.Bundle.CREATOR);
          this.onAvailableCommandsChangedFromPlayer(_arg0, _arg1);
          break;
        }
        case TRANSACTION_onAvailableCommandsChangedFromSession:
        {
          int _arg0;
          _arg0 = data.readInt();
          android.os.Bundle _arg1;
          _arg1 = _Parcel.readTypedObject(data, android.os.Bundle.CREATOR);
          android.os.Bundle _arg2;
          _arg2 = _Parcel.readTypedObject(data, android.os.Bundle.CREATOR);
          this.onAvailableCommandsChangedFromSession(_arg0, _arg1, _arg2);
          break;
        }
        case TRANSACTION_onRenderedFirstFrame:
        {
          int _arg0;
          _arg0 = data.readInt();
          this.onRenderedFirstFrame(_arg0);
          break;
        }
        case TRANSACTION_onExtrasChanged:
        {
          int _arg0;
          _arg0 = data.readInt();
          android.os.Bundle _arg1;
          _arg1 = _Parcel.readTypedObject(data, android.os.Bundle.CREATOR);
          this.onExtrasChanged(_arg0, _arg1);
          break;
        }
        case TRANSACTION_onSessionActivityChanged:
        {
          int _arg0;
          _arg0 = data.readInt();
          android.app.PendingIntent _arg1;
          _arg1 = _Parcel.readTypedObject(data, android.app.PendingIntent.CREATOR);
          this.onSessionActivityChanged(_arg0, _arg1);
          break;
        }
        case TRANSACTION_onError:
        {
          int _arg0;
          _arg0 = data.readInt();
          android.os.Bundle _arg1;
          _arg1 = _Parcel.readTypedObject(data, android.os.Bundle.CREATOR);
          this.onError(_arg0, _arg1);
          break;
        }
        case TRANSACTION_onChildrenChanged:
        {
          int _arg0;
          _arg0 = data.readInt();
          java.lang.String _arg1;
          _arg1 = data.readString();
          int _arg2;
          _arg2 = data.readInt();
          android.os.Bundle _arg3;
          _arg3 = _Parcel.readTypedObject(data, android.os.Bundle.CREATOR);
          this.onChildrenChanged(_arg0, _arg1, _arg2, _arg3);
          break;
        }
        case TRANSACTION_onSearchResultChanged:
        {
          int _arg0;
          _arg0 = data.readInt();
          java.lang.String _arg1;
          _arg1 = data.readString();
          int _arg2;
          _arg2 = data.readInt();
          android.os.Bundle _arg3;
          _arg3 = _Parcel.readTypedObject(data, android.os.Bundle.CREATOR);
          this.onSearchResultChanged(_arg0, _arg1, _arg2, _arg3);
          break;
        }
        default:
        {
          return super.onTransact(code, data, reply, flags);
        }
      }
      return true;
    }
    private static class Proxy implements androidx.media3.session.IMediaController
    {
      private android.os.IBinder mRemote;
      Proxy(android.os.IBinder remote)
      {
        mRemote = remote;
      }
      @Override public android.os.IBinder asBinder()
      {
        return mRemote;
      }
      public java.lang.String getInterfaceDescriptor()
      {
        return DESCRIPTOR;
      }
      // Id < 3000 is reserved to avoid potential collision with media2 1.x.
      @Override public void onConnected(int seq, android.os.Bundle connectionResult) throws android.os.RemoteException
      {
        android.os.Parcel _data = android.os.Parcel.obtain();
        try {
          _data.writeInterfaceToken(DESCRIPTOR);
          _data.writeInt(seq);
          _Parcel.writeTypedObject(_data, connectionResult, 0);
          boolean _status = mRemote.transact(Stub.TRANSACTION_onConnected, _data, null, android.os.IBinder.FLAG_ONEWAY);
        }
        finally {
          _data.recycle();
        }
      }
      @Override public void onSessionResult(int seq, android.os.Bundle sessionResult) throws android.os.RemoteException
      {
        android.os.Parcel _data = android.os.Parcel.obtain();
        try {
          _data.writeInterfaceToken(DESCRIPTOR);
          _data.writeInt(seq);
          _Parcel.writeTypedObject(_data, sessionResult, 0);
          boolean _status = mRemote.transact(Stub.TRANSACTION_onSessionResult, _data, null, android.os.IBinder.FLAG_ONEWAY);
        }
        finally {
          _data.recycle();
        }
      }
      @Override public void onLibraryResult(int seq, android.os.Bundle libraryResult) throws android.os.RemoteException
      {
        android.os.Parcel _data = android.os.Parcel.obtain();
        try {
          _data.writeInterfaceToken(DESCRIPTOR);
          _data.writeInt(seq);
          _Parcel.writeTypedObject(_data, libraryResult, 0);
          boolean _status = mRemote.transact(Stub.TRANSACTION_onLibraryResult, _data, null, android.os.IBinder.FLAG_ONEWAY);
        }
        finally {
          _data.recycle();
        }
      }
      @Override public void onSetCustomLayout(int seq, java.util.List<android.os.Bundle> commandButtonList) throws android.os.RemoteException
      {
        android.os.Parcel _data = android.os.Parcel.obtain();
        try {
          _data.writeInterfaceToken(DESCRIPTOR);
          _data.writeInt(seq);
          _Parcel.writeTypedList(_data, commandButtonList, 0);
          boolean _status = mRemote.transact(Stub.TRANSACTION_onSetCustomLayout, _data, null, android.os.IBinder.FLAG_ONEWAY);
        }
        finally {
          _data.recycle();
        }
      }
      @Override public void onCustomCommand(int seq, android.os.Bundle command, android.os.Bundle args) throws android.os.RemoteException
      {
        android.os.Parcel _data = android.os.Parcel.obtain();
        try {
          _data.writeInterfaceToken(DESCRIPTOR);
          _data.writeInt(seq);
          _Parcel.writeTypedObject(_data, command, 0);
          _Parcel.writeTypedObject(_data, args, 0);
          boolean _status = mRemote.transact(Stub.TRANSACTION_onCustomCommand, _data, null, android.os.IBinder.FLAG_ONEWAY);
        }
        finally {
          _data.recycle();
        }
      }
      @Override public void onDisconnected(int seq) throws android.os.RemoteException
      {
        android.os.Parcel _data = android.os.Parcel.obtain();
        try {
          _data.writeInterfaceToken(DESCRIPTOR);
          _data.writeInt(seq);
          boolean _status = mRemote.transact(Stub.TRANSACTION_onDisconnected, _data, null, android.os.IBinder.FLAG_ONEWAY);
        }
        finally {
          _data.recycle();
        }
      }
      /** Deprecated: Use onPlayerInfoChangedWithExclusions from MediaControllerStub#VERSION_INT=2. */
      @Override public void onPlayerInfoChanged(int seq, android.os.Bundle playerInfoBundle, boolean isTimelineExcluded) throws android.os.RemoteException
      {
        android.os.Parcel _data = android.os.Parcel.obtain();
        try {
          _data.writeInterfaceToken(DESCRIPTOR);
          _data.writeInt(seq);
          _Parcel.writeTypedObject(_data, playerInfoBundle, 0);
          _data.writeInt(((isTimelineExcluded)?(1):(0)));
          boolean _status = mRemote.transact(Stub.TRANSACTION_onPlayerInfoChanged, _data, null, android.os.IBinder.FLAG_ONEWAY);
        }
        finally {
          _data.recycle();
        }
      }
      /** Introduced to deprecate onPlayerInfoChanged (from MediaControllerStub#VERSION_INT=2). */
      @Override public void onPlayerInfoChangedWithExclusions(int seq, android.os.Bundle playerInfoBundle, android.os.Bundle playerInfoExclusions) throws android.os.RemoteException
      {
        android.os.Parcel _data = android.os.Parcel.obtain();
        try {
          _data.writeInterfaceToken(DESCRIPTOR);
          _data.writeInt(seq);
          _Parcel.writeTypedObject(_data, playerInfoBundle, 0);
          _Parcel.writeTypedObject(_data, playerInfoExclusions, 0);
          boolean _status = mRemote.transact(Stub.TRANSACTION_onPlayerInfoChangedWithExclusions, _data, null, android.os.IBinder.FLAG_ONEWAY);
        }
        finally {
          _data.recycle();
        }
      }
      @Override public void onPeriodicSessionPositionInfoChanged(int seq, android.os.Bundle sessionPositionInfo) throws android.os.RemoteException
      {
        android.os.Parcel _data = android.os.Parcel.obtain();
        try {
          _data.writeInterfaceToken(DESCRIPTOR);
          _data.writeInt(seq);
          _Parcel.writeTypedObject(_data, sessionPositionInfo, 0);
          boolean _status = mRemote.transact(Stub.TRANSACTION_onPeriodicSessionPositionInfoChanged, _data, null, android.os.IBinder.FLAG_ONEWAY);
        }
        finally {
          _data.recycle();
        }
      }
      @Override public void onAvailableCommandsChangedFromPlayer(int seq, android.os.Bundle commandsBundle) throws android.os.RemoteException
      {
        android.os.Parcel _data = android.os.Parcel.obtain();
        try {
          _data.writeInterfaceToken(DESCRIPTOR);
          _data.writeInt(seq);
          _Parcel.writeTypedObject(_data, commandsBundle, 0);
          boolean _status = mRemote.transact(Stub.TRANSACTION_onAvailableCommandsChangedFromPlayer, _data, null, android.os.IBinder.FLAG_ONEWAY);
        }
        finally {
          _data.recycle();
        }
      }
      @Override public void onAvailableCommandsChangedFromSession(int seq, android.os.Bundle sessionCommandsBundle, android.os.Bundle playerCommandsBundle) throws android.os.RemoteException
      {
        android.os.Parcel _data = android.os.Parcel.obtain();
        try {
          _data.writeInterfaceToken(DESCRIPTOR);
          _data.writeInt(seq);
          _Parcel.writeTypedObject(_data, sessionCommandsBundle, 0);
          _Parcel.writeTypedObject(_data, playerCommandsBundle, 0);
          boolean _status = mRemote.transact(Stub.TRANSACTION_onAvailableCommandsChangedFromSession, _data, null, android.os.IBinder.FLAG_ONEWAY);
        }
        finally {
          _data.recycle();
        }
      }
      @Override public void onRenderedFirstFrame(int seq) throws android.os.RemoteException
      {
        android.os.Parcel _data = android.os.Parcel.obtain();
        try {
          _data.writeInterfaceToken(DESCRIPTOR);
          _data.writeInt(seq);
          boolean _status = mRemote.transact(Stub.TRANSACTION_onRenderedFirstFrame, _data, null, android.os.IBinder.FLAG_ONEWAY);
        }
        finally {
          _data.recycle();
        }
      }
      @Override public void onExtrasChanged(int seq, android.os.Bundle extras) throws android.os.RemoteException
      {
        android.os.Parcel _data = android.os.Parcel.obtain();
        try {
          _data.writeInterfaceToken(DESCRIPTOR);
          _data.writeInt(seq);
          _Parcel.writeTypedObject(_data, extras, 0);
          boolean _status = mRemote.transact(Stub.TRANSACTION_onExtrasChanged, _data, null, android.os.IBinder.FLAG_ONEWAY);
        }
        finally {
          _data.recycle();
        }
      }
      @Override public void onSessionActivityChanged(int seq, android.app.PendingIntent pendingIntent) throws android.os.RemoteException
      {
        android.os.Parcel _data = android.os.Parcel.obtain();
        try {
          _data.writeInterfaceToken(DESCRIPTOR);
          _data.writeInt(seq);
          _Parcel.writeTypedObject(_data, pendingIntent, 0);
          boolean _status = mRemote.transact(Stub.TRANSACTION_onSessionActivityChanged, _data, null, android.os.IBinder.FLAG_ONEWAY);
        }
        finally {
          _data.recycle();
        }
      }
      @Override public void onError(int seq, android.os.Bundle sessionError) throws android.os.RemoteException
      {
        android.os.Parcel _data = android.os.Parcel.obtain();
        try {
          _data.writeInterfaceToken(DESCRIPTOR);
          _data.writeInt(seq);
          _Parcel.writeTypedObject(_data, sessionError, 0);
          boolean _status = mRemote.transact(Stub.TRANSACTION_onError, _data, null, android.os.IBinder.FLAG_ONEWAY);
        }
        finally {
          _data.recycle();
        }
      }
      // Next Id for MediaController: 3015
      @Override public void onChildrenChanged(int seq, java.lang.String parentId, int itemCount, android.os.Bundle libraryParams) throws android.os.RemoteException
      {
        android.os.Parcel _data = android.os.Parcel.obtain();
        try {
          _data.writeInterfaceToken(DESCRIPTOR);
          _data.writeInt(seq);
          _data.writeString(parentId);
          _data.writeInt(itemCount);
          _Parcel.writeTypedObject(_data, libraryParams, 0);
          boolean _status = mRemote.transact(Stub.TRANSACTION_onChildrenChanged, _data, null, android.os.IBinder.FLAG_ONEWAY);
        }
        finally {
          _data.recycle();
        }
      }
      @Override public void onSearchResultChanged(int seq, java.lang.String query, int itemCount, android.os.Bundle libraryParams) throws android.os.RemoteException
      {
        android.os.Parcel _data = android.os.Parcel.obtain();
        try {
          _data.writeInterfaceToken(DESCRIPTOR);
          _data.writeInt(seq);
          _data.writeString(query);
          _data.writeInt(itemCount);
          _Parcel.writeTypedObject(_data, libraryParams, 0);
          boolean _status = mRemote.transact(Stub.TRANSACTION_onSearchResultChanged, _data, null, android.os.IBinder.FLAG_ONEWAY);
        }
        finally {
          _data.recycle();
        }
      }
    }
    static final int TRANSACTION_onConnected = (android.os.IBinder.FIRST_CALL_TRANSACTION + 3000);
    static final int TRANSACTION_onSessionResult = (android.os.IBinder.FIRST_CALL_TRANSACTION + 3001);
    static final int TRANSACTION_onLibraryResult = (android.os.IBinder.FIRST_CALL_TRANSACTION + 3002);
    static final int TRANSACTION_onSetCustomLayout = (android.os.IBinder.FIRST_CALL_TRANSACTION + 3003);
    static final int TRANSACTION_onCustomCommand = (android.os.IBinder.FIRST_CALL_TRANSACTION + 3004);
    static final int TRANSACTION_onDisconnected = (android.os.IBinder.FIRST_CALL_TRANSACTION + 3005);
    static final int TRANSACTION_onPlayerInfoChanged = (android.os.IBinder.FIRST_CALL_TRANSACTION + 3006);
    static final int TRANSACTION_onPlayerInfoChangedWithExclusions = (android.os.IBinder.FIRST_CALL_TRANSACTION + 3012);
    static final int TRANSACTION_onPeriodicSessionPositionInfoChanged = (android.os.IBinder.FIRST_CALL_TRANSACTION + 3007);
    static final int TRANSACTION_onAvailableCommandsChangedFromPlayer = (android.os.IBinder.FIRST_CALL_TRANSACTION + 3008);
    static final int TRANSACTION_onAvailableCommandsChangedFromSession = (android.os.IBinder.FIRST_CALL_TRANSACTION + 3009);
    static final int TRANSACTION_onRenderedFirstFrame = (android.os.IBinder.FIRST_CALL_TRANSACTION + 3010);
    static final int TRANSACTION_onExtrasChanged = (android.os.IBinder.FIRST_CALL_TRANSACTION + 3011);
    static final int TRANSACTION_onSessionActivityChanged = (android.os.IBinder.FIRST_CALL_TRANSACTION + 3013);
    static final int TRANSACTION_onError = (android.os.IBinder.FIRST_CALL_TRANSACTION + 3014);
    static final int TRANSACTION_onChildrenChanged = (android.os.IBinder.FIRST_CALL_TRANSACTION + 4000);
    static final int TRANSACTION_onSearchResultChanged = (android.os.IBinder.FIRST_CALL_TRANSACTION + 4001);
  }
  public static final java.lang.String DESCRIPTOR = "androidx.media3.session.IMediaController";
  // Id < 3000 is reserved to avoid potential collision with media2 1.x.
  public void onConnected(int seq, android.os.Bundle connectionResult) throws android.os.RemoteException;
  public void onSessionResult(int seq, android.os.Bundle sessionResult) throws android.os.RemoteException;
  public void onLibraryResult(int seq, android.os.Bundle libraryResult) throws android.os.RemoteException;
  public void onSetCustomLayout(int seq, java.util.List<android.os.Bundle> commandButtonList) throws android.os.RemoteException;
  public void onCustomCommand(int seq, android.os.Bundle command, android.os.Bundle args) throws android.os.RemoteException;
  public void onDisconnected(int seq) throws android.os.RemoteException;
  /** Deprecated: Use onPlayerInfoChangedWithExclusions from MediaControllerStub#VERSION_INT=2. */
  public void onPlayerInfoChanged(int seq, android.os.Bundle playerInfoBundle, boolean isTimelineExcluded) throws android.os.RemoteException;
  /** Introduced to deprecate onPlayerInfoChanged (from MediaControllerStub#VERSION_INT=2). */
  public void onPlayerInfoChangedWithExclusions(int seq, android.os.Bundle playerInfoBundle, android.os.Bundle playerInfoExclusions) throws android.os.RemoteException;
  public void onPeriodicSessionPositionInfoChanged(int seq, android.os.Bundle sessionPositionInfo) throws android.os.RemoteException;
  public void onAvailableCommandsChangedFromPlayer(int seq, android.os.Bundle commandsBundle) throws android.os.RemoteException;
  public void onAvailableCommandsChangedFromSession(int seq, android.os.Bundle sessionCommandsBundle, android.os.Bundle playerCommandsBundle) throws android.os.RemoteException;
  public void onRenderedFirstFrame(int seq) throws android.os.RemoteException;
  public void onExtrasChanged(int seq, android.os.Bundle extras) throws android.os.RemoteException;
  public void onSessionActivityChanged(int seq, android.app.PendingIntent pendingIntent) throws android.os.RemoteException;
  public void onError(int seq, android.os.Bundle sessionError) throws android.os.RemoteException;
  // Next Id for MediaController: 3015
  public void onChildrenChanged(int seq, java.lang.String parentId, int itemCount, android.os.Bundle libraryParams) throws android.os.RemoteException;
  public void onSearchResultChanged(int seq, java.lang.String query, int itemCount, android.os.Bundle libraryParams) throws android.os.RemoteException;
  /** @hide */
  static class _Parcel {
    static private <T> T readTypedObject(
        android.os.Parcel parcel,
        android.os.Parcelable.Creator<T> c) {
      if (parcel.readInt() != 0) {
          return c.createFromParcel(parcel);
      } else {
          return null;
      }
    }
    static private <T extends android.os.Parcelable> void writeTypedObject(
        android.os.Parcel parcel, T value, int parcelableFlags) {
      if (value != null) {
        parcel.writeInt(1);
        value.writeToParcel(parcel, parcelableFlags);
      } else {
        parcel.writeInt(0);
      }
    }
    static private <T extends android.os.Parcelable> void writeTypedList(
        android.os.Parcel parcel, java.util.List<T> value, int parcelableFlags) {
      if (value == null) {
        parcel.writeInt(-1);
      } else {
        int N = value.size();
        int i = 0;
        parcel.writeInt(N);
        while (i < N) {
    writeTypedObject(parcel, value.get(i), parcelableFlags);
          i++;
        }
      }
    }
  }
}
