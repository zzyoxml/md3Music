package com.md3music.md3music;

import java.util.concurrent.atomic.AtomicLong;

/** 线程安全的媒体键单飞队列：执行中的命令之外只保留最新待执行命令。 */
final class LatestMediaCommandQueue {
    private static final AtomicLong NEXT_COMMAND_ID = new AtomicLong();

    static final class Command {
        final String method;
        final long id;

        Command(String method, long id) {
            this.method = method;
            this.id = id;
        }
    }

    private Command pending;
    private boolean inFlight;

    /** 入队并判断调用方是否需要启动唯一的派发线程。 */
    synchronized boolean offer(String method) {
        pending = new Command(method, NEXT_COMMAND_ID.incrementAndGet());
        if (inFlight) return false;
        inFlight = true;
        return true;
    }

    /** 原子取走最新待执行命令。 */
    synchronized Command take() {
        Command command = pending;
        pending = null;
        return command;
    }

    /** 派发失败时放回原命令；期间若已到达更新命令，则保留新命令。 */
    synchronized void requeueIfEmpty(Command command) {
        if (pending == null) pending = command;
    }

    /** 有界重试耗尽时只丢弃对应命令，不能删除期间到达的更新命令。 */
    synchronized void dropIfPending(long commandId) {
        if (pending != null && pending.id == commandId) pending = null;
    }

    synchronized boolean hasPending() { return pending != null; }

    /**
     * 当前派发线程准备退出时调用。
     * 返回true表示已有新命令待处理，inFlight继续归当前线程所有；
     * 返回false则原子释放单飞状态，后续offer会启动新线程。
     */
    synchronized boolean finishDispatch() {
        if (pending != null) return true;
        inFlight = false;
        return false;
    }

    synchronized void discardPending() {
        pending = null;
    }
}
