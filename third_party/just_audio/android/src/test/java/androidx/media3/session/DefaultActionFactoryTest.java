package androidx.media3.session;

import static android.view.KeyEvent.KEYCODE_MEDIA_NEXT;
import static android.view.KeyEvent.KEYCODE_MEDIA_PAUSE;
import static android.view.KeyEvent.KEYCODE_MEDIA_PLAY;
import static androidx.media3.common.Player.COMMAND_PLAY_PAUSE;
import static androidx.media3.common.Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM;
import static org.junit.Assert.assertEquals;

import org.junit.Test;

public class DefaultActionFactoryTest {

  @Test
  public void repeatedPlayPauseNotificationActionKeepsItsOriginalDirection() {
    assertEquals(KEYCODE_MEDIA_PAUSE, DefaultActionFactory.toKeyCode(COMMAND_PLAY_PAUSE, true));
    assertEquals(KEYCODE_MEDIA_PLAY, DefaultActionFactory.toKeyCode(COMMAND_PLAY_PAUSE, false));
  }

  @Test
  public void nextActionStillUsesNextKey() {
    assertEquals(KEYCODE_MEDIA_NEXT, DefaultActionFactory.toKeyCode(COMMAND_SEEK_TO_NEXT_MEDIA_ITEM, true));
  }
}
