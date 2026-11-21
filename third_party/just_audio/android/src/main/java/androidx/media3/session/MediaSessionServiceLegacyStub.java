/*
 * Copyright 2019 The Android Open Source Project
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package androidx.media3.session;

import static androidx.media3.common.util.Util.postOrRun;

import android.os.Bundle;
import androidx.annotation.Nullable;
import androidx.media3.common.util.ConditionVariable;
import androidx.media3.common.util.Log;
import androidx.media3.session.MediaSession.ControllerInfo;
import androidx.media3.session.legacy.MediaBrowserCompat.MediaItem;
import androidx.media3.session.legacy.MediaBrowserServiceCompat;
import androidx.media3.session.legacy.MediaSessionCompat;
import androidx.media3.session.legacy.MediaSessionManager;
import androidx.media3.session.legacy.MediaSessionManager.RemoteUserInfo;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.atomic.AtomicReference;

/**
 * Implementation of {@link MediaBrowserServiceCompat} for interoperability between {@link
 * MediaLibraryService} and {@code android.support.v4.media.MediaBrowserCompat}.
 */
/* package */ class MediaSessionServiceLegacyStub extends MediaBrowserServiceCompat {

  private static final String TAG = "MSSLegacyStub";

  private final MediaSessionManager manager;
  private final MediaSessionImpl sessionImpl;
  private final ConnectedControllersManager<RemoteUserInfo> connectedControllersManager;

  /** Creates a new instance. Caller must call {@link #initialize} to the instance. */
  public MediaSessionServiceLegacyStub(MediaSessionImpl sessionImpl) {
    super();
    manager = MediaSessionManager.getSessionManager(sessionImpl.getContext());
    this.sessionImpl = sessionImpl;
    connectedControllersManager = new ConnectedControllersManager<>(sessionImpl);
  }

  public void initialize(MediaSessionCompat.Token token) {
    attachToBaseContext(sessionImpl.getContext());
    onCreate();
    setSessionToken(token);
  }

  @Override
  @Nullable
  public BrowserRoot onGetRoot(
      @Nullable String clientPackageName, int clientUid, @Nullable Bundle rootHints) {
    RemoteUserInfo info = getCurrentBrowserInfo();
    MediaSession.ControllerInfo controller =
        createControllerInfo(info, rootHints != null ? rootHints : Bundle.EMPTY);

    AtomicReference<MediaSession.ConnectionResult> resultReference = new AtomicReference<>();
    ConditionVariable haveResult = new ConditionVariable();
    postOrRun(
        sessionImpl.getApplicationHandler(),
        () -> {
          resultReference.set(sessionImpl.onConnectOnHandler(controller));
          haveResult.open();
        });
    try {
      haveResult.block();
    } catch (InterruptedException e) {
      Log.e(TAG, "Couldn't get a result from onConnect", e);
      return null;
    }
    MediaSession.ConnectionResult result = resultReference.get();
    if (!result.isAccepted) {
      return null;
    }
    connectedControllersManager.addController(
        info, controller, result.availableSessionCommands, result.availablePlayerCommands);
    // No library root, but keep browser compat connected to allow getting session.
    return MediaUtils.defaultBrowserRoot;
  }

  @Override
  public void onLoadChildren(@Nullable String parentId, Result<List<MediaItem>> result) {
    onLoadChildren(parentId, result, /* options= */ null);
  }

  /**
   * MD3Music fork v67：legacy browse 搜索（车机/第三方桥接按关键词取候选列表）。
   *
   * <p>默认实现（基类 {@code MediaBrowserServiceCompat.onSearch}）会置
   * {@code RESULT_FLAG_ON_SEARCH_NOT_IMPLEMENTED} 并 sendResult(null)，客户端拿到的是
   * 错误而不是「0 条结果」。这里转给 App 注入的 SearchProvider。
   *
   * <p>两个必须遵守的约定（见 {@code performSearch}）：
   *
   * <ul>
   *   <li>提供方必须在返回前 {@code detach()} 或 {@code sendResult()}，否则基类同步抛
   *       IllegalStateException；
   *   <li>空结果必须回 {@code emptyList()}，回 {@code null} 会被转成 RESULT_ERROR。
   * </ul>
   *
   * <p>提供方缺席或抛错时兜底回空列表：宁可让客户端看到「0 条结果」，也不要让它看到
   * 「搜索未实现」——后者会促使桥接端关闭搜索入口。
   */
  @Override
  public void onSearch(
      @Nullable String query, @Nullable Bundle extras, Result<List<MediaItem>> result) {
    MediaSessionService.SearchProvider provider = MediaSessionService.searchProvider;
    if (provider != null) {
      try {
        if (provider.onSearch(query, extras, result)) {
          return;
        }
      } catch (Throwable t) {
        Log.w(TAG, "search provider failed", t);
      }
    }
    result.sendResult(Collections.<MediaItem>emptyList());
  }

  /**
   * MD3Music fork v39：带分页参数的子节点查询。
   *
   * <p>原生默认实现（见基类注释）会把 options 丢掉、只回调两参版本——vivo 原子随身听
   * 的分页键 `vivomusicmix_key_media_page` 正是走 options，必须重写本重载才能拿到页号。
   */
  @Override
  public void onLoadChildren(
      @Nullable String parentId, Result<List<MediaItem>> result, @Nullable Bundle options) {
    MediaSessionService.BrowseChildrenProvider provider = browseChildrenProvider;
    if (provider == null) {
      result.sendResult(/* result= */ null);
      return;
    }
    List<MediaItem> items;
    try {
      items = provider.onLoadChildren(parentId, options);
    } catch (Throwable t) {
      Log.w(TAG, "browse children provider failed", t);
      items = null;
    }
    result.sendResult(items == null ? Collections.<MediaItem>emptyList() : items);
  }

  /**
   * MD3Music fork v39：legacy browse 子节点提供者（App 侧注入 vivo 原子随身听的三棵
   * 列表树）。接口声明在 {@link MediaSessionService}——本类是包内可见，App 侧无法引用
   * 它的嵌套类型。v40：volatile——写发生在 impl.lock 内，读在本类主线程无锁。
   */
  @Nullable
  private volatile MediaSessionService.BrowseChildrenProvider browseChildrenProvider;

  /** MD3Music fork v39：注入子节点提供者。 */
  public void setBrowseChildrenProvider(
      @Nullable MediaSessionService.BrowseChildrenProvider provider) {
    browseChildrenProvider = provider;
  }

  public ControllerInfo createControllerInfo(RemoteUserInfo info, Bundle rootHints) {
    return new ControllerInfo(
        info,
        ControllerInfo.LEGACY_CONTROLLER_VERSION,
        ControllerInfo.LEGACY_CONTROLLER_INTERFACE_VERSION,
        manager.isTrustedForMediaControl(info),
        /* cb= */ null,
        /* connectionHints= */ rootHints);
  }

  public final MediaSessionManager getMediaSessionManager() {
    return manager;
  }

  public final ConnectedControllersManager<RemoteUserInfo> getConnectedControllersManager() {
    return connectedControllersManager;
  }
}
