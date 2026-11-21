package com.md3music.md3music

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CarPowerSignalTest {

    @Test
    fun switchOnMapsKnownActionsToPause() {
        assertEquals(
            "pause",
            CarPowerSignal.commandFor("com.roadrover.roados.action.qq_music_pause", enabled = true)
        )
        assertEquals(
            "pause",
            CarPowerSignal.commandFor("android.intent.action.ACTION_SHUTDOWN", enabled = true)
        )
    }

    @Test
    fun switchOffNeverProducesACommand() {
        for (action in CarPowerSignal.ACTIONS) {
            assertNull(CarPowerSignal.commandFor(action, enabled = false))
        }
    }

    @Test
    fun screenEventsAreObservedButNeverPause() {
        // 手机端息屏听歌是核心场景：SCREEN_OFF 只能用于记日志，绝不能触发暂停
        assertTrue(CarPowerSignal.shouldObserve("android.intent.action.SCREEN_OFF"))
        assertTrue(CarPowerSignal.shouldObserve("android.intent.action.SCREEN_ON"))
        assertNull(CarPowerSignal.commandFor("android.intent.action.SCREEN_OFF", enabled = true))
        assertNull(CarPowerSignal.commandFor("android.intent.action.SCREEN_ON", enabled = true))
    }

    @Test
    fun unrelatedActionsAreIgnored() {
        assertNull(CarPowerSignal.commandFor("android.intent.action.MEDIA_BUTTON", enabled = true))
        assertNull(CarPowerSignal.commandFor("com.md3music.md3music.ACTION_NEXT", enabled = true))
        assertNull(CarPowerSignal.commandFor("", enabled = true))
        assertNull(CarPowerSignal.commandFor(null, enabled = true))
        assertFalse(CarPowerSignal.shouldObserve(null))
        assertFalse(CarPowerSignal.shouldObserve("com.roadrover.roados.action.qq_music_pause"))
    }

    @Test
    fun everyDeclaredActionHasACommandWhenEnabled() {
        for (action in CarPowerSignal.ACTIONS) {
            assertEquals("pause", CarPowerSignal.commandFor(action, enabled = true))
        }
    }

    @Test
    fun allActionsCoversBothGroupsWithoutDuplicates() {
        assertEquals(
            CarPowerSignal.ACTIONS.size + CarPowerSignal.OBSERVE_ONLY_ACTIONS.size,
            CarPowerSignal.ALL_ACTIONS.size
        )
        assertTrue(CarPowerSignal.ALL_ACTIONS.containsAll(CarPowerSignal.ACTIONS))
        assertTrue(CarPowerSignal.ALL_ACTIONS.containsAll(CarPowerSignal.OBSERVE_ONLY_ACTIONS))
    }
}
