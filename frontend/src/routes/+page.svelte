<script lang="ts">
	import { env } from '$env/dynamic/public';
	import { GlobalChannelClient, type ConnectionState } from '$lib/realtime/phoenix';
	import type { BrushEvent, SnapshotPayload } from '$lib/types/wire';
	import { onDestroy, onMount } from 'svelte';

	type SandEngineLike = {
		set_color(r: number, g: number, b: number): void;
		paint(x: number, y: number, add: boolean): void;
		paint_colored(x: number, y: number, add: boolean, r: number, g: number, b: number): void;
		step(): void;
		render(): void;
		import_state(bytes: Uint8Array): void;
	};

	type SandModuleLike = {
		default: (moduleOrPath?: string | URL | WebAssembly.Module) => Promise<unknown>;
		SandEngine: {
			new_async(canvasId: string): Promise<SandEngineLike>;
		};
	};

	type PresenceState = Record<string, { metas: unknown[] }>;
	type PresenceDiff = {
		joins?: PresenceState;
		leaves?: PresenceState;
	};

	const WIDTH = 800;
	const HEIGHT = 600;
	const BRUSH_RADIUS = 7;
	const MAX_SEEN_EVENTS = 20_000;
	const SNAPSHOT_IDLE_RESYNC_MS = 30_000;
	const SNAPSHOT_IDLE_INPUT_GRACE_MS = 1_500;

	let canvasEl: HTMLCanvasElement | null = null;
	let eng: SandEngineLike | null = null;
	let raf = 0;

	let realtime: GlobalChannelClient | null = null;
	const cleanupRealtime: Array<() => void> = [];

	let connectionState: ConnectionState = 'connecting';
	let usersOnline = 0;
	let presenceState: PresenceState = {};
	let userColors: Array<{ id: string; color: string }> = [];
	let localColorCss = 'rgb(214 181 97)';
	let localColorHex = '#d6b561';

	let lmb = false;
	let rmb = false;
	let mx = 0;
	let my = 0;

	const userId = makeId('user');
	const seenBrushIds = new Set<string>();
	const seenOrder: string[] = [];
	const pendingLocalBrushIds = new Set<string>();
	let latestSnapshot: SnapshotPayload | null = null;
	let shouldForceSnapshotImport = true;
	let hasAppliedSnapshot = false;
	let lastSnapshotAppliedAt = 0;
	let lastLocalInputAt = 0;

	function makeId(prefix: string): string {
		if (typeof crypto !== 'undefined' && 'randomUUID' in crypto) {
			return `${prefix}-${crypto.randomUUID()}`;
		}
		return `${prefix}-${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;
	}

	function hslToRgb01(h: number, s: number, l: number): [number, number, number] {
		const c = (1 - Math.abs(2 * l - 1)) * s;
		const hp = h / 60;
		const x = c * (1 - Math.abs((hp % 2) - 1));

		let r = 0;
		let g = 0;
		let b = 0;

		if (hp >= 0 && hp < 1) {
			r = c;
			g = x;
		} else if (hp < 2) {
			r = x;
			g = c;
		} else if (hp < 3) {
			g = c;
			b = x;
		} else if (hp < 4) {
			g = x;
			b = c;
		} else if (hp < 5) {
			r = x;
			b = c;
		} else {
			r = c;
			b = x;
		}

		const m = l - c / 2;
		return [r + m, g + m, b + m];
	}

	function randomConnectionColor(): [number, number, number] {
		const hue = Math.random() * 360;
		return hslToRgb01(hue, 0.72, 0.58);
	}

	function rgbCss(r: number, g: number, b: number): string {
		const rr = Math.round(r * 255);
		const gg = Math.round(g * 255);
		const bb = Math.round(b * 255);
		return `rgb(${rr} ${gg} ${bb})`;
	}

	function rgbHex(r: number, g: number, b: number): string {
		const toHex = (v: number) =>
			Math.round(v * 255)
				.toString(16)
				.padStart(2, '0');
		return `#${toHex(r)}${toHex(g)}${toHex(b)}`;
	}

	function normalizeHexColor(value: unknown): string | null {
		if (typeof value !== 'string') return null;
		const color = value.trim().toLowerCase();
		return /^#[0-9a-f]{6}$/.test(color) ? color : null;
	}

	function rememberSeenBrush(id: string): void {
		if (seenBrushIds.has(id)) return;
		seenBrushIds.add(id);
		seenOrder.push(id);
		if (seenOrder.length > MAX_SEEN_EVENTS) {
			const oldest = seenOrder.shift();
			if (oldest) seenBrushIds.delete(oldest);
		}
	}

	function updateMouseFromEvent(e: PointerEvent) {
		if (!canvasEl) return;
		const rect = canvasEl.getBoundingClientRect();
		const scaleX = canvasEl.width / rect.width;
		const scaleY = canvasEl.height / rect.height;
		mx = (e.clientX - rect.left) * scaleX;
		my = (e.clientY - rect.top) * scaleY;
	}

	function clearMouseButtons() {
		lmb = false;
		rmb = false;
	}

	function handlePointerUp(e: PointerEvent) {
		if (e.button === 0) lmb = false;
		if (e.button === 2) rmb = false;
	}

	function emitBrush(add: boolean) {
		lastLocalInputAt = performance.now();

		const event: BrushEvent = {
			id: makeId('evt'),
			userId,
			color: localColorHex,
			x: mx,
			y: my,
			add,
			radius: BRUSH_RADIUS,
			t: Date.now()
		};

		rememberSeenBrush(event.id);
		pendingLocalBrushIds.add(event.id);
		eng?.paint(event.x, event.y, event.add);
		realtime?.push('brush', event);
	}

	function tick() {
		raf = requestAnimationFrame(tick);
		if (!eng) return;
		eng.step();
		eng.render();
	}

	function paintFromButtons() {
		if (lmb) emitBrush(true);
		if (rmb) emitBrush(false);
	}

	function updateUsersOnline() {
		const entries = Object.entries(presenceState);
		usersOnline = entries.length;

		userColors = entries.map(([id, presence]) => {
			const metas = (presence?.metas ?? []) as Array<Record<string, unknown>>;
			const color =
				metas.map((meta) => normalizeHexColor(meta.color)).find((value) => value !== null) ??
				'#94a3b8';
			return { id, color };
		});
	}

	function coercePresenceState(payload: unknown): PresenceState {
		if (!payload || typeof payload !== 'object') return {};
		return payload as PresenceState;
	}

	function applyPresenceDiff(payload: unknown) {
		const diff = (payload ?? {}) as PresenceDiff;

		if (diff.joins) {
			for (const [id, value] of Object.entries(diff.joins)) {
				presenceState[id] = value;
			}
		}

		if (diff.leaves) {
			for (const id of Object.keys(diff.leaves)) {
				delete presenceState[id];
			}
		}

		updateUsersOnline();
	}

	async function decodeSnapshotBytes(bytesB64: string): Promise<Uint8Array> {
		const compressed = Uint8Array.from(atob(bytesB64), (c) => c.charCodeAt(0));

		if (typeof DecompressionStream === 'undefined') {
			throw new Error('Browser does not support DecompressionStream');
		}

		const ds = new DecompressionStream('gzip');
		const stream = new Blob([compressed]).stream().pipeThrough(ds);
		const buffer = await new Response(stream).arrayBuffer();
		return new Uint8Array(buffer);
	}

	async function applySnapshot(snapshot: SnapshotPayload) {
		latestSnapshot = snapshot;
		if (!eng) return;

		try {
			const bytes = await decodeSnapshotBytes(snapshot.bytesB64);
			if (bytes.length !== WIDTH * HEIGHT * 4) return;
			eng.import_state(bytes);
			pendingLocalBrushIds.clear();
			hasAppliedSnapshot = true;
			shouldForceSnapshotImport = false;
			lastSnapshotAppliedAt = performance.now();
		} catch (error) {
			console.error('Snapshot decode/import failed', error);
		}
	}

	function shouldApplySnapshot(): boolean {
		if (!hasAppliedSnapshot || shouldForceSnapshotImport) {
			return true;
		}

		const now = performance.now();
		const idleFromInput = now - lastLocalInputAt > SNAPSHOT_IDLE_INPUT_GRACE_MS;
		const idleFromAcks = pendingLocalBrushIds.size === 0;
		const idleFromButtons = !lmb && !rmb;
		const longSinceLastApply = now - lastSnapshotAppliedAt >= SNAPSHOT_IDLE_RESYNC_MS;

		return idleFromInput && idleFromAcks && idleFromButtons && longSinceLastApply;
	}

	function connectRealtime() {
		realtime = new GlobalChannelClient(env.PUBLIC_WS_ENDPOINT ?? '', userId, localColorHex);

		cleanupRealtime.push(
			realtime.onStatus((state) => {
				connectionState = state;
				if (state === 'disconnected') {
					usersOnline = 0;
					presenceState = {};
					userColors = [];
					shouldForceSnapshotImport = true;
					hasAppliedSnapshot = false;
				}
			})
		);

		cleanupRealtime.push(
			realtime.on('presence_state', (payload: unknown) => {
				presenceState = coercePresenceState(payload);
				updateUsersOnline();
			})
		);

		cleanupRealtime.push(
			realtime.on('presence_diff', (payload: unknown) => {
				applyPresenceDiff(payload);
			})
		);

		cleanupRealtime.push(
			realtime.on('brush', (payload: BrushEvent) => {
				if (!payload?.id) return;
				if (seenBrushIds.has(payload.id)) {
					pendingLocalBrushIds.delete(payload.id);
					return;
				}

				rememberSeenBrush(payload.id);
				const rgb = normalizeHexColor(payload.color);
				if (rgb) {
					const r = Number.parseInt(rgb.slice(1, 3), 16) / 255;
					const g = Number.parseInt(rgb.slice(3, 5), 16) / 255;
					const b = Number.parseInt(rgb.slice(5, 7), 16) / 255;
					eng?.paint_colored(payload.x, payload.y, payload.add, r, g, b);
				} else {
					eng?.paint(payload.x, payload.y, payload.add);
				}
			})
		);

		cleanupRealtime.push(
			realtime.on('snapshot', (payload: SnapshotPayload) => {
				if (!shouldApplySnapshot()) {
					latestSnapshot = payload;
					return;
				}

				void applySnapshot(payload);
			})
		);

		cleanupRealtime.push(
			realtime.on('reset', () => {
				eng?.import_state(new Uint8Array(WIDTH * HEIGHT * 4));
				pendingLocalBrushIds.clear();
				shouldForceSnapshotImport = true;
				hasAppliedSnapshot = false;
			})
		);

		realtime.connect();
	}

	function sendReset() {
		shouldForceSnapshotImport = true;
		hasAppliedSnapshot = false;
		realtime?.push('reset', { id: makeId('reset') });
	}

	onMount(async () => {
		if (!canvasEl) return;
		canvasEl.id = 'sand-canvas';
		const [r, g, b] = randomConnectionColor();
		localColorCss = rgbCss(r, g, b);
		localColorHex = rgbHex(r, g, b);

		const wasmPath = '/wasm/physics_engine.js';
		const wasm = (await import(/* @vite-ignore */ wasmPath)) as unknown as SandModuleLike;
		await wasm.default();
		eng = await wasm.SandEngine.new_async(canvasEl.id);
		eng.set_color(r, g, b);

		if (latestSnapshot) {
			await applySnapshot(latestSnapshot);
		}

		connectRealtime();
		window.addEventListener('pointerup', handlePointerUp);
		window.addEventListener('pointercancel', clearMouseButtons);

		raf = requestAnimationFrame(tick);
	});

	onDestroy(() => {
		cancelAnimationFrame(raf);
		window.removeEventListener('pointerup', handlePointerUp);
		window.removeEventListener('pointercancel', clearMouseButtons);

		for (const dispose of cleanupRealtime) dispose();
		cleanupRealtime.length = 0;
		realtime?.disconnect();
		realtime = null;

		clearMouseButtons();
		eng = null;
	});
</script>

<div
	class="min-h-screen bg-[radial-gradient(circle_at_20%_20%,#2d3748_0%,#111827_55%,#020617_100%)] p-4 text-slate-100 md:p-6"
>
	<div
		class="mx-auto flex min-h-[calc(100vh-2rem)] w-full max-w-6xl flex-col justify-center md:min-h-[calc(100vh-3rem)]"
	>
		<div class="mb-4 flex flex-wrap items-center justify-between gap-3">
			<div>
				<h1 class="text-xl font-semibold tracking-tight md:text-2xl">Global Sand Simulation</h1>
				<p class="text-sm text-slate-300">
					LMB add, RMB erase, R reset. All users share one authoritative world.
				</p>
			</div>
			<div class="flex items-center gap-3 text-sm">
				<span
					class={`rounded-full px-3 py-1 ${
						connectionState === 'connected'
							? 'bg-emerald-600/30 text-emerald-200'
							: 'bg-rose-600/30 text-rose-200'
					}`}
				>
					{connectionState}
				</span>
				<span class="rounded-full bg-slate-700/70 px-3 py-1 text-slate-100"
					>users: {usersOnline}</span
				>
				<span
					class="inline-flex items-center gap-2 rounded-full bg-slate-700/70 px-3 py-1 text-slate-100"
				>
					<span
						class="h-3 w-3 rounded-full border border-slate-200/60"
						style:background={localColorCss}
					></span>
					color
				</span>
				<span
					class="inline-flex min-h-8 items-center gap-1 rounded-full bg-slate-700/70 px-3 py-1 text-slate-100"
				>
					{#if userColors.length === 0}
						<span class="text-xs text-slate-300">no users</span>
					{:else}
						{#each userColors as user}
							<span
								class="h-2.5 w-2.5 rounded-full border border-slate-200/60"
								style:background={user.color}
								title={user.id}
							></span>
						{/each}
					{/if}
				</span>
				<button
					type="button"
					on:click={sendReset}
					class="rounded-lg border border-slate-600 bg-slate-800 px-3 py-2 text-sm hover:bg-slate-700 active:bg-slate-900"
				>
					Reset
				</button>
			</div>
		</div>

		<div class="overflow-hidden rounded-xl border border-slate-700 bg-black/30 p-3 shadow-2xl">
			<canvas
				bind:this={canvasEl}
				tabindex="0"
				class="block aspect-4/3 w-full rounded-lg border border-slate-700 bg-[#12121a] select-none [image-rendering:pixelated]"
				on:contextmenu|preventDefault
				on:pointerdown={(e) => {
					updateMouseFromEvent(e);
					canvasEl?.setPointerCapture(e.pointerId);
					if (e.button === 0) {
						lmb = true;
						emitBrush(true);
					}
					if (e.button === 2) {
						rmb = true;
						emitBrush(false);
					}
				}}
				on:pointerup={(e) => {
					updateMouseFromEvent(e);
					if (canvasEl?.hasPointerCapture(e.pointerId)) {
						canvasEl.releasePointerCapture(e.pointerId);
					}
					handlePointerUp(e);
				}}
				on:pointermove={(e) => {
					updateMouseFromEvent(e);
					paintFromButtons();
				}}
				on:pointercancel={clearMouseButtons}
				on:mouseleave={clearMouseButtons}
				on:keydown={(e) => {
					if (e.key.toLowerCase() === 'r') sendReset();
				}}
			></canvas>
		</div>
	</div>
</div>
