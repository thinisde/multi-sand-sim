// See https://svelte.dev/docs/kit/types#app.d.ts
// for information about these interfaces
declare global {
	namespace App {
		// interface Error {}
		// interface Locals {}
		// interface PageData {}
		// interface PageState {}
		// interface Platform {}
	}
}

declare module '/wasm/physics_engine.js' {
	const init: (moduleOrPath?: string | URL | WebAssembly.Module) => Promise<unknown>;

	export class SandEngine {
		static new_async(canvasId: string): Promise<{
			set_color(r: number, g: number, b: number): void;
			paint(x: number, y: number, add: boolean): void;
			paint_colored(x: number, y: number, add: boolean, r: number, g: number, b: number): void;
			step(): void;
			render(): void;
			import_state(bytes: Uint8Array): void;
		}>;
	}

	export default init;
}

export {};
