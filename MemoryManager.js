// Memory allocator for common uniforms. Allows to utilize singule array for all uniforms of the same data type.

export const bufferf32 = new Float32Array(128);
let nextIdx = 0;

export function allocf32(size = 0)
{
	// TODO: grow buffer by closest multiples relative to size suitable for WebGPU.
	// TODO: check size to be a multiple of data type alignment, which follows WebGPU spec.

	if (size <= 0)
	{
		throw new Error("Requested <= 0 memory size! Can't allocate no memory.");
	}

	if (size > bufferf32.length - nextIdx)
	{
		throw new Error(`Not enough memory! Requested ${size} f32s, but only have ${bufferf32.length - nextIdx} available.`)
	}

	const memoryStart = nextIdx;
	nextIdx = Math.min(nextIdx + size, bufferf32.length);

	console.log("CPU uniforms f32 memory nextIdx", nextIdx);

	return memoryStart;
}

// Doesn't work, entities outside won't know their index to buffer is invalid.
// TODO: Perhaps it needs to track available memory gaps and allocated them is requested size fits.
// export function freef32(startIndex = 0, size = 0) {
// 	size = Math.min(size, bufferf32.length - startIdx);
// 	let i = startIdx;

// 	for (i = startIdx; i < bufferf32.length; i++)
// 	{
// 		bufferf32[startIdx] = bufferf32[startIdx + size];
// 	}

// 	nextIdx = Math.max(nextIdx - size, 0);
// }

export function writef32(startIdx = 0, ...args)
{
	bufferf32.set(args, startIdx);
}

export function writef32Array(startIdx = 0, data = [])
{
	bufferf32.set(data, startIdx);
}
