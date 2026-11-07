/*
 * This file is auto-generated.  DO NOT MODIFY.
 */
package androidx.media3.session;
/**
 * Interface from MediaController to MediaSessionService.
 * 
 * <p>It's for internal use only, not intended to be used by library users.
 */
// Note: Keep this interface oneway. Otherwise a malicious app may make a blocking call to make
// session service frozen.
public interface IMediaSessionService extends android.os.IInterface
{
  /** Default implementation for IMediaSessionService. */
  public static class Default implements androidx.media3.session.IMediaSessionService
  {
    // Id < 3000 is reserved to avoid potential collision with media2 1.x.
    @Override public void connect(androidx.media3.session.IMediaController caller, android.os.Bundle connectionRequest) throws android.os.RemoteException
    {
    }
    @Override
    public android.os.IBinder asBinder() {
      return null;
    }
  }
  /** Local-side IPC implementation stub class. */
  public static abstract class Stub extends android.os.Binder implements androidx.media3.session.IMediaSessionService
  {
    /** Construct the stub at attach it to the interface. */
    public Stub()
    {
      this.attachInterface(this, DESCRIPTOR);
    }
    /**
     * Cast an IBinder object into an androidx.media3.session.IMediaSessionService interface,
     * generating a proxy if needed.
     */
    public static androidx.media3.session.IMediaSessionService asInterface(android.os.IBinder obj)
    {
      if ((obj==null)) {
        return null;
      }
      android.os.IInterface iin = obj.queryLocalInterface(DESCRIPTOR);
      if (((iin!=null)&&(iin instanceof androidx.media3.session.IMediaSessionService))) {
        return ((androidx.media3.session.IMediaSessionService)iin);
      }
      return new androidx.media3.session.IMediaSessionService.Stub.Proxy(obj);
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
        case TRANSACTION_connect:
        {
          androidx.media3.session.IMediaController _arg0;
          _arg0 = androidx.media3.session.IMediaController.Stub.asInterface(data.readStrongBinder());
          android.os.Bundle _arg1;
          _arg1 = _Parcel.readTypedObject(data, android.os.Bundle.CREATOR);
          this.connect(_arg0, _arg1);
          break;
        }
        default:
        {
          return super.onTransact(code, data, reply, flags);
        }
      }
      return true;
    }
    private static class Proxy implements androidx.media3.session.IMediaSessionService
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
      @Override public void connect(androidx.media3.session.IMediaController caller, android.os.Bundle connectionRequest) throws android.os.RemoteException
      {
        android.os.Parcel _data = android.os.Parcel.obtain();
        try {
          _data.writeInterfaceToken(DESCRIPTOR);
          _data.writeStrongInterface(caller);
          _Parcel.writeTypedObject(_data, connectionRequest, 0);
          boolean _status = mRemote.transact(Stub.TRANSACTION_connect, _data, null, android.os.IBinder.FLAG_ONEWAY);
        }
        finally {
          _data.recycle();
        }
      }
    }
    static final int TRANSACTION_connect = (android.os.IBinder.FIRST_CALL_TRANSACTION + 3000);
  }
  public static final java.lang.String DESCRIPTOR = "androidx.media3.session.IMediaSessionService";
  // Id < 3000 is reserved to avoid potential collision with media2 1.x.
  public void connect(androidx.media3.session.IMediaController caller, android.os.Bundle connectionRequest) throws android.os.RemoteException;
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
  }
}
