"""Share local arrival observations; each subscriber decides what an observation means."""
import asyncio


class BackWatch:
    def __init__(self, native, *, native_events=False):
        self.native = native
        self.windows = {}
        self.native_events = native_events
        self.control = asyncio.Lock()

    async def _sync_events(self):
        if self.native_events:
            async with self.control:
                await self.native("arrivalWatching", timeout=5, on=bool(self.windows))

    def notify(self):
        for state in self.windows.values():
            state["wake"].set()

    async def _run(self, window, state):
        while True:
            state["wake"].clear()
            try:
                seen = await self.native("isBack", timeout=5, window=window)
            except asyncio.CancelledError:
                raise
            except Exception:
                seen = {"noAnswer": True, "error": "观察暂不可用"}
            async with state["condition"]:
                state["seen"] = seen
                state["at"] = asyncio.get_running_loop().time()
                state["version"] += 1
                state["condition"].notify_all()
            try:
                await asyncio.wait_for(state["wake"].wait(), timeout=5 if self.native_events else min(state["users"].values(), default=2))
            except asyncio.TimeoutError:
                pass

    async def observe(self, window, every, *, immediate=True):
        state = self.windows.get(window)
        if state is None:
            state = {"condition": asyncio.Condition(), "wake": asyncio.Event(), "version": 0, "seen": None, "at": 0, "users": {}}
            self.windows[window] = state
            state["task"] = asyncio.create_task(self._run(window, state))
        token = object()
        state["users"][token] = every
        state["wake"].set()
        version, next_at = 0, asyncio.get_running_loop().time() + (0 if immediate else every)
        first_wake = asyncio.get_running_loop().call_later(every, state["wake"].set) if self.native_events and not immediate else None
        try:
            await self._sync_events()
            while True:
                async with state["condition"]:
                    await state["condition"].wait_for(lambda: state["version"] > version and state["at"] >= next_at)
                    version, seen = state["version"], state["seen"]
                next_at = 0 if self.native_events else asyncio.get_running_loop().time() + every
                yield seen
        finally:
            if first_wake:
                first_wake.cancel()
            state["users"].pop(token, None)
            if not state["users"]:
                state["task"].cancel()
                if self.windows.get(window) is state:
                    del self.windows[window]
                await self._sync_events()
