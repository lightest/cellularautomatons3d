import { UI } from "./ui.js";
import { vec3, mat4, quat } from "./libs/wgpu-matrix.module.js";

const GRID_SIZE = 128;
const WORK_GROUP_SIZE = 4;
const MAX_FRAME_DURATION = 16; // Amount of ms to hold one frame for.
const TRANSLATION_SPEED = .15;
const MIN_TRANSLATION_SPEED_MUL = .01;
const MAX_TRANSLATION_SPEED_MUL = 100;

class MainModule
{
	constructor()
	{
		this._ui = new UI({
			gridRows: GRID_SIZE,
			gridCols: GRID_SIZE
		});

		this._prevTime = performance.now();
		this._frameDuration = 0;
		this._simulationStep = 0;
		this._updateLoopBinded = this._updateLoop.bind(this);
		this._controlData = new Uint32Array(8); // Has to be multiples of 16 bytes.
		this._fov = 0;
		this._sampleCount = 1;
		this._viewMat = undefined;
		this._inverseViewMat = undefined;
		this._projectionMat = undefined;
		this._projViewMatInv = undefined;
		this._simulationIsActive = 1;
		this._translationSpeedMul = .2;
		this.simulationIsActive = this._simulationIsActive;

		this._lightSource = {
			x: 0, y: 1.5, z: 0,
			magnitude: 1,
			buffer: new Float32Array([0, 0, 1, 1]),

			update()
			{
				this.buffer[0] = this.x;
				this.buffer[1] = this.y;
				this.buffer[2] = this.z;
				this.buffer[3] = this.magnitude;
			}
		};

		this._eyeVector = new Float32Array([0, 0, 1]);
		this._target = new Float32Array(3);
		this._up = new Float32Array([0, 1, 0]);

		this._pressedKeys = {};
		this._mouse = {
			x: 0,
			y: 0,
			prevX: -1,
			prevY: -1
		};

		this._resolutionDependentAssets = {};
	}

	async init()
	{
		this._viewMat = mat4.lookAt(
			this._eyeVector,
			this._target,
			this._up
		);

		mat4.translate(this._viewMat, [0, 0, 3], this._viewMat);
		this._inverseViewMat = mat4.inverse(this._viewMat);
		this._projectionMat = mat4.create();
		this._projViewMatInv = mat4.create();
		this._updatePerspectiveMatrix();
		mat4.multiply(this._projectionMat, this._inverseViewMat, this._projViewMatInv);

		this._adapter = await navigator.gpu.requestAdapter({
			powerPreference: "high-performance"
		});
		this._device = await this._adapter.requestDevice();
		console.log(this._adapter, this._device);

		this._canvas = document.querySelector(".main-canvas");
		this._ctx = this._canvas.getContext("webgpu");
		this._ctx.configure({
			device: this._device,
			format: navigator.gpu.getPreferredCanvasFormat(),
			alphaMode: "premultiplied"
		});
		this._createResolutionDependentAssests();
		const buffers = this._getCubeVertices(.85);
		// const buffers = this._getPlaneVertices();
		this._setupVertexBuffer(buffers.vertex);
		this._setupIndexBuffer(buffers.index);
		const uniformBuffers = this._setupUniformsBuffers();
		const storageBuffers = this._setupStorageBuffers();
		const bindGroupLayout = this._setupBindGroups(uniformBuffers, storageBuffers);
		await this._setupPipelines(bindGroupLayout);
		this._setupRenderPassDescriptor();
		this._handleResize();
		console.log(this._ctx);
		this._addEventListeners();

		// this._ui.init();
		// this._ui.registerHandler("pointermove", this._onPointermove.bind(this));
		// this._ui.registerHandler("pointerdown", this._onPointerdown.bind(this));
		// this._ui.registerHandler("pointerup", this._onPointerup.bind(this));
		// this._ui.registerHandler("ctrl+c", this._copyHandler.bind(this));
		// this._ui.registerHandler("ctrl+v", this._pasteHandler.bind(this));

		this._updateLoop();
	}

	set simulationIsActive(v)
	{
		this._simulationIsActive = Number(v);
		this._controlData[3] = this._simulationIsActive;
	}

	set fov(angle)
	{
		this._fov = angle * Math.PI / 180;
	}

	_updatePerspectiveMatrix()
	{
		this.fov = 75;
		const aspect = window.innerWidth / window.innerHeight;
		const near = .01;
		const far = 1000;
		mat4.perspective(this._fov, aspect, near, far, this._projectionMat);
	}

	_updateMatrices()
	{
		mat4.inverse(this._viewMat, this._inverseViewMat);
		mat4.multiply(this._projectionMat, this._inverseViewMat, this._projViewMatInv);
	}

	_onPointermove(e)
	{
		const gridX = Math.max(0, Math.min(GRID_SIZE - 1, Math.round((e.clientX / window.innerWidth) * (GRID_SIZE - 1))));
		const gridY = Math.max(0, Math.min(GRID_SIZE - 1, Math.round((1 - e.clientY / window.innerHeight) * (GRID_SIZE - 1))));
		const idx = this._getCellIdx(gridX, gridY);

		// TODO: create a structure which manages offset.
		const offset = 4;
		this._controlData[offset] = gridX;
		this._controlData[offset + 1] = gridY;
	}

	_onPointerdown(e)
	{
		// TODO: create a structure which manages offset.
		const offset = 0;
		const button = Math.min(e.button, 2);
		this._controlData[offset + button] = 1;
	}

	_onPointerup(e)
	{
		// TODO: create a structure which manages offset.
		const offset = 0;
		const button = Math.min(e.button, 2);
		this._controlData[offset + button] = 0;
	}

	async _getShaderSources()
	{
		let vertexSrc = await fetch("./shaders/vertex.wgsl");
		vertexSrc = await vertexSrc.text();
		let fragmentSrc = await fetch("./shaders/fragment.wgsl");
		fragmentSrc = await fragmentSrc.text();
		const shaders = `${vertexSrc}\n${fragmentSrc}`;

		return shaders;
	}

	async _getComputeShaderSources ()
	{
		let computeSrc = await fetch("./shaders/compute.wgsl");
		computeSrc = await computeSrc.text();

		return computeSrc;
	}

	_createResolutionDependentAssests()
	{
		const renderTarget = this._device.createTexture({
			size: [this._canvas.width, this._canvas.height],
			sampleCount: this._sampleCount,
			format: navigator.gpu.getPreferredCanvasFormat(),
			usage: GPUTextureUsage.RENDER_ATTACHMENT
		});

		const depthTexture = this._device.createTexture({
			size: [this._canvas.width, this._canvas.height],
			sampleCount: this._sampleCount,
			format: "depth24plus",
			usage: GPUTextureUsage.RENDER_ATTACHMENT
		});

		this._resolutionDependentAssets = {
			renderTarget,
			depthTexture
		};
	}

	_reapplyResolutionDependantAssests()
	{
		if (this._sampleCount > 1)
		{
			this._renderPassDescriptor.colorAttachments[0].view = this._resolutionDependentAssets.renderTarget.createView();
		}
		this._renderPassDescriptor.depthStencilAttachment.view = this._resolutionDependentAssets.depthTexture.createView();
	}

	_handleResize()
	{
		const pixelRatio = window.devicePixelRatio || 1.0;
		const width = window.innerWidth * pixelRatio | 0;
		const height = window.innerHeight * pixelRatio | 0;
		if (this._canvas.width !== width || this._canvas.height !== height)
		{
			this._canvas.width = width;
			this._canvas.height = height;
		}

		this._createResolutionDependentAssests();
		this._reapplyResolutionDependantAssests();
		this._updatePerspectiveMatrix();
	}

	_handleWheel(e)
	{
		this._translationSpeedMul += -Math.sign(e.deltaY) * .05;
		this._translationSpeedMul = Math.max(MIN_TRANSLATION_SPEED_MUL, Math.min(this._translationSpeedMul, MAX_TRANSLATION_SPEED_MUL));
	}

	_handleKeydown(e)
	{
		// console.log(e);
		this._pressedKeys[e.code] = true;
		this._applyKeyboardInputUI(e);
	}

	_handleKeyup(e)
	{
		this._pressedKeys[e.code] = false;
	}

	_handleMouseMove(e)
	{
		// Handling initial state to avoid giant deltas.
		if (this._mouse.prevX < 0)
		{
			this._mouse.prevX = e.clientX
			this._mouse.prevY = e.clientY
		}
		else
		{
			this._mouse.prevX = this._mouse.x;
			this._mouse.prevY = this._mouse.y;
		}

		this._mouse.x = e.clientX;
		this._mouse.y = e.clientY;

		// TODO: research this.
		this._mouse.movementX = e.movementX;
		this._mouse.movementY = e.movementY;

		// Applying mouse input on mouse event instead of update loop yields better results.
		this._applyMouseInput();
	}

	_applyKeyboardInputUI(e)
	{
		if (e.code === "KeyL")
		{
			this._canvas.requestPointerLock();
		}
	}

	_applyKeyboardInput()
	{
		const translationVector = new Float32Array(3);
		const rotationAxis = new Float32Array(3);
		let rotationMagnitude = 0;

		if (this._pressedKeys["KeyW"])
		{
			translationVector[2] = -TRANSLATION_SPEED;
		}

		if (this._pressedKeys["KeyS"])
		{
			translationVector[2] = TRANSLATION_SPEED;
		}

		if (this._pressedKeys["KeyA"])
		{
			translationVector[0] = -TRANSLATION_SPEED;
		}

		if (this._pressedKeys["KeyD"])
		{
			translationVector[0] = TRANSLATION_SPEED;
		}

		if (this._pressedKeys["KeyR"])
		{
			translationVector[1] = TRANSLATION_SPEED;
		}

		if (this._pressedKeys["KeyF"])
		{
			translationVector[1] = -TRANSLATION_SPEED;
		}

		if (this._pressedKeys["ArrowLeft"])
		{
			rotationAxis[1] = 1;
			rotationMagnitude = .1;
		}

		if (this._pressedKeys["ArrowRight"])
		{
			rotationAxis[1] = -1;
			rotationMagnitude = .1;
		}

		if (this._pressedKeys["ArrowUp"])
		{
			rotationAxis[0] = 1;
			rotationMagnitude = .1;
		}

		if (this._pressedKeys["ArrowDown"])
		{
			rotationAxis[0] = -1;
			rotationMagnitude = .1;
		}

		if (this._pressedKeys["KeyQ"])
		{
			rotationAxis[2] = 1;
			rotationMagnitude = .05;
		}

		if (this._pressedKeys["KeyE"])
		{
			rotationAxis[2] = -1;
			rotationMagnitude = .05;
		}

		translationVector[0] *= this._translationSpeedMul;
		translationVector[1] *= this._translationSpeedMul;
		translationVector[2] *= this._translationSpeedMul;

		mat4.translate(this._viewMat, translationVector, this._viewMat);

		if (rotationMagnitude !== 0)
		{
			mat4.rotate(this._viewMat, rotationAxis, rotationMagnitude, this._viewMat);
		}
	}

	_applyMouseInput()
	{
		if (document.pointerLockElement === this._canvas)
		{
			const rotationAxis = new Float32Array(3);
			const dx = this._mouse.movementX;
			const dy = this._mouse.movementY;

			if (dx !== undefined && dy !== undefined && (dx !== 0 || dy !== 0))
			{
				// For some reason when using dx and dy directly to set the rotation axis it works better.
				// Proportionality in relation to magnitude?
				rotationAxis[0] = -dy;
				rotationAxis[1] = -dx;

				// Attempting to approximate magnitued of rotation by using the magnitude of vector formed by mouse dx dy movement.
				// TODO: think of this more.
				const magnitude = .001 * Math.sqrt( (dx ** 2) + (dy ** 2) );
				mat4.rotate(this._viewMat, rotationAxis, magnitude, this._viewMat);

				this._mouse.movementX = 0;
				this._mouse.movementY = 0;
			}
		}
	}

	_getPlaneVertices()
	{
		const buffer = new Float32Array([
			0.5, 0.5, 0, 1,
			0, 0, 1,
			-0.5, -0.5, 0, 1,
			0, 0, 1,
			0.5, -0.5, 0, 1,
			0, 0, 1,
			-0.5, 0.5, 0, 1,
			0, 0, 1,
		]);

		const indices = new Uint32Array([
			0, 1, 2, 0, 3, 1
		]);

		return {
			vertex: buffer,
			index: indices
		};
	}

	_getCubeVertices(cubeSize = .5)
	{
		// Vertices with face normals.
		const buffer = new Float32Array([
			// Front face
			cubeSize, cubeSize, cubeSize, 1,
			0, 0, 1,
			-cubeSize, -cubeSize, cubeSize, 1,
			0, 0, 1,
			cubeSize, -cubeSize, cubeSize, 1,
			0, 0, 1,
			cubeSize, cubeSize, cubeSize, 1,
			0, 0, 1,
			-cubeSize, cubeSize, cubeSize, 1,
			0, 0, 1,
			-cubeSize, -cubeSize, cubeSize, 1,
			0, 0, 1,

			// Right
			cubeSize, cubeSize, cubeSize, 1,
			1, 0, 0,
			cubeSize, -cubeSize, cubeSize, 1,
			1, 0, 0,
			cubeSize, cubeSize, -cubeSize, 1,
			1, 0, 0,
			cubeSize, -cubeSize, -cubeSize, 1,
			1, 0, 0,
			cubeSize, cubeSize, -cubeSize, 1,
			1, 0, 0,
			cubeSize, -cubeSize, cubeSize, 1,
			1, 0, 0,

			// Top
			cubeSize, cubeSize, cubeSize, 1,
			0, 1, 0,
			cubeSize, cubeSize, -cubeSize, 1,
			0, 1, 0,
			-cubeSize, cubeSize, cubeSize, 1,
			0, 1, 0,
			-cubeSize, cubeSize, cubeSize, 1,
			0, 1, 0,
			cubeSize, cubeSize, -cubeSize, 1,
			0, 1, 0,
			-cubeSize, cubeSize, -cubeSize, 1,
			0, 1, 0,

			// Back
			-cubeSize, cubeSize, -cubeSize, 1,
			0, 0, -1,
			cubeSize, cubeSize, -cubeSize, 1,
			0, 0, -1,
			cubeSize, -cubeSize, -cubeSize, 1,
			0, 0, -1,
			-cubeSize, cubeSize, -cubeSize, 1,
			0, 0, -1,
			cubeSize, -cubeSize, -cubeSize, 1,
			0, 0, -1,
			-cubeSize, -cubeSize, -cubeSize, 1,
			0, 0, -1,

			// Left
			-cubeSize, -cubeSize, cubeSize, 1,
			-1, 0, 0,
			-cubeSize, cubeSize, cubeSize, 1,
			-1, 0, 0,
			-cubeSize, cubeSize, -cubeSize, 1,
			-1, 0, 0,
			-cubeSize, -cubeSize, cubeSize, 1,
			-1, 0, 0,
			-cubeSize, cubeSize, -cubeSize, 1,
			-1, 0, 0,
			-cubeSize, -cubeSize, -cubeSize, 1,
			-1, 0, 0,

			//Bottom
			-cubeSize, -cubeSize, -cubeSize, 1,
			0, -1, 0,
			cubeSize, -cubeSize, -cubeSize, 1,
			0, -1, 0,
			cubeSize, -cubeSize, cubeSize, 1,
			0, -1, 0,
			-cubeSize, -cubeSize, -cubeSize, 1,
			0, -1, 0,
			cubeSize, -cubeSize, cubeSize, 1,
			0, -1, 0,
			-cubeSize, -cubeSize, cubeSize, 1,
			0, -1, 0
		]);

		// Without normals
		// const buffer = new Float32Array([
		// 	0.5, 0.5, 0.5, 1,
		// 	-0.5, -0.5, 0.5, 1,
		// 	0.5, -0.5, 0.5, 1,
		// 	-0.5, 0.5, 0.5, 1,
		// 	0.5, 0.5, -0.5, 1,
		// 	0.5, -0.5, -0.5, 1,
		// 	-0.5, 0.5, -0.5, 1,
		// 	-0.5, -0.5, -0.5, 1
		// ]);

		// const indices = new Uint32Array([
		// 	0, 1, 2, 0, 3, 1, // Front
		// 	0, 2, 4, 5, 4, 2, // Right
		// 	0, 4, 3, 3, 4, 6, // Top
		// 	6, 4, 5, 6, 5, 7, // Back
		// 	1, 3, 6, 1, 6, 7, // Left
		// 	7, 5, 2, 7, 2, 1  // Bottom
		// ]);

		const indices = new Uint32Array([
			0, 1, 2, 3, 4, 5, // Front
			6, 7, 8, 9, 10, 11, // Right
			12, 13, 14, 15, 16, 17, // Top
			18, 19, 20, 21, 22, 23, // Back
			24, 25, 26, 27, 28, 29, // Left
			30, 31, 32, 33, 34, 35  // Bottom
		]);

		return {
			vertex: buffer,
			index: indices
		};
	}

	_setupVertexBuffer(data)
	{
		this._vertexBuffer = this._device.createBuffer({
			size: data.byteLength,
			usage: GPUBufferUsage.VERTEX | GPUBufferUsage.COPY_DST
		});
		const bufferWriteStartIdx = 0
		const dataStartIdx = 0;
		this._device.queue.writeBuffer(
			this._vertexBuffer,
			bufferWriteStartIdx,
			data,
			dataStartIdx,
			data.length
		);
	}

	_getCellIdx (x, y)
	{
		if (x < 0)
		{
			x = GRID_SIZE + x;
		}
		if (y < 0)
		{
			y = GRID_SIZE + y;
		}
		return (x % GRID_SIZE) + (y % GRID_SIZE) * GRID_SIZE;
	}

	_getCellIdx3D(x, y, z)
	{
		if (x < 0)
		{
			x = GRID_SIZE + x;
		}
		if (y < 0)
		{
			y = GRID_SIZE + y;
		}
		if (z < 0)
		{
			z = GRID_SIZE + z;
		}
		return (x % GRID_SIZE) + (y % GRID_SIZE) * GRID_SIZE + (z % GRID_SIZE) * GRID_SIZE * GRID_SIZE;
	}

	_setupIndexBuffer(data)
	{
		this._indexBuffer = this._device.createBuffer({
			size: data.byteLength,
			usage: GPUBufferUsage.INDEX | GPUBufferUsage.COPY_DST
		});
		const bufferWriteStartIdx = 0;
		this._device.queue.writeBuffer(
			this._indexBuffer,
			bufferWriteStartIdx,
			data
		);
	}

	_setupUniformsBuffers ()
	{
		const gridDimensionsData = new Float32Array([GRID_SIZE, GRID_SIZE, GRID_SIZE]);
		const gridDimensionsBuffer = this._device.createBuffer({
			label: "grid uniforms",
			size: gridDimensionsData.byteLength,
			usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST
		});

		const controlDataBuffer = this._device.createBuffer({
			label: "pointer data",
			size: this._controlData.byteLength,
			usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST
		});

		const viewMatrixBuffer = this._device.createBuffer({
			label: "viewmatrix buffer",
			size: this._inverseViewMat.byteLength,
			usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST
		});

		const projViewMatrixBuffer = this._device.createBuffer({
			label: "projviewmat buffer",
			size: this._viewMat.byteLength,
			usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST
		});

		const lightsBuffer = this._device.createBuffer({
			label: "lights buffer",
			size: this._lightSource.buffer.byteLength,
			usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST
		});

		this._device.queue.writeBuffer(gridDimensionsBuffer, 0, gridDimensionsData);
		this._device.queue.writeBuffer(controlDataBuffer, 0, this._controlData);
		this._device.queue.writeBuffer(viewMatrixBuffer, 0, this._viewMat);
		this._device.queue.writeBuffer(projViewMatrixBuffer, 0, this._projViewMatInv);
		this._device.queue.writeBuffer(lightsBuffer, 0, this._lightSource.buffer);

		this._uniformBuffers = {
			gridDimensionsBuffer,
			controlDataBuffer,
			viewMatrixBuffer,
			projViewMatrixBuffer,
			lightsBuffer,
		};

		return this._uniformBuffers;
	}

	_setupStorageBuffers ()
	{
		let i = 0;
		const cellStateData = new Uint32Array(GRID_SIZE * GRID_SIZE * GRID_SIZE);

		this._stagingBuffer = this._device.createBuffer({
			label: "staging_buf",
			size: cellStateData.byteLength,
			usage: GPUBufferUsage.MAP_READ | GPUBufferUsage.COPY_DST
		});

		const cellStorageBuffers = [
			this._device.createBuffer({
				label: "cell_state_0",
				size: cellStateData.byteLength,
				usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST | GPUBufferUsage.COPY_SRC
			}),

			this._device.createBuffer({
				label: "cell_state_1",
				size: cellStateData.byteLength,
				usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST | GPUBufferUsage.COPY_SRC
			})
		];

		this._cellStorageBuffers = cellStorageBuffers;

		// for (i = 0; i < cellStateData.length; i += 3)
		// {
		// 	cellStateData[i] = Math.round(Math.random() + .1);
		// }

		const center = Math.floor(GRID_SIZE * .5);
		cellStateData[this._getCellIdx3D(center, center, center)] = 1;
		console.log(cellStateData);

		// Center of the grid;
		const x = Math.floor(GRID_SIZE * .5);
		const y = Math.floor(GRID_SIZE * .5);
		// Glider.
		// cellStateData[this._getCellIdx(x + 1, y)] = 1;
		// cellStateData[this._getCellIdx(x + 1, y - 1)] = 1;
		// cellStateData[this._getCellIdx(x, y - 1)] = 1;
		// cellStateData[this._getCellIdx(x - 1, y - 1)] = 1;
		// cellStateData[this._getCellIdx(x, y + 1)] = 1;


		this._device.queue.writeBuffer(
			cellStorageBuffers[0],
			0,
			cellStateData
		);

		// for (i = 0; i < cellStateData.length; i++)
		// {
		// 	cellStateData[i] = i % 2;
		// }

		this._device.queue.writeBuffer(
			cellStorageBuffers[1],
			0,
			cellStateData
		);

		return cellStorageBuffers;
	}

	_resetStorageBuffers()
	{
		const cellStateData = new Uint32Array(GRID_SIZE * GRID_SIZE * GRID_SIZE);
		const center = Math.floor(GRID_SIZE * .5);
		cellStateData[this._getCellIdx3D(center, center, center)] = 1;

		this._device.queue.writeBuffer(
			this._cellStorageBuffers[0],
			0,
			cellStateData
		);

		this._device.queue.writeBuffer(
			this._cellStorageBuffers[1],
			0,
			cellStateData
		);
	}

	async _setupPipelines(bindGroupLayout)
	{
		// TODO: Should this be a separate func?
		const shaderCode = await this._getShaderSources();
		const computeShaderCode = await this._getComputeShaderSources();
		const shaderModule = this._device.createShaderModule({
			code: shaderCode
		});

		const computeShaderModule = this._device.createShaderModule({
			code: computeShaderCode
		});

		const pipelineLayout = this._device.createPipelineLayout({
			bindGroupLayouts: [ bindGroupLayout ]
		});

		// const buffersLayour = [
		// 	{
		// 		attributes: [
		// 			{
		// 				shaderLocation: 0,
		// 				offset: 0,
		// 				format: "float32x4"
		// 			},
		// 			{
		// 				shaderLocation: 1,
		// 				offset: 16, // bytes
		// 				format: "float32x4"
		// 			}
		// 		],
		// 		arrayStride: 32, // bytes
		// 		stepMode: "vertex"
		// 	}
		// ];

		const buffersLayour = [
			{
				attributes: [
					{
						shaderLocation: 0,
						offset: 0,
						format: "float32x4"
					},
					{
						shaderLocation: 1,
						offset: 16, // bytes
						format: "float32x3"
					}
				],
				arrayStride: 28, // bytes
				stepMode: "vertex"
			}
		];

		const renderPipelineDescriptor = {
			vertex: {
				module: shaderModule,
				entryPoint: "vertex_main",
				buffers: buffersLayour,
			},

			fragment: {
				module: shaderModule,
				entryPoint: "fragment_main",
				targets: [
					{
						format: navigator.gpu.getPreferredCanvasFormat()
					}
				]
			},

			primitive: {
				topology: "triangle-list",
				cullMode: "back"
			},

			layout: pipelineLayout,

			multisample: {
				count: this._sampleCount
			},

			// TODO: read more on this:
			depthStencil: {
				depthWriteEnabled: true,
				depthCompare: "less",
				format: "depth24plus"
			}
		};

		const computePipelineDescriptor = {
			layout: pipelineLayout,
			compute: {
				module: computeShaderModule,
				entryPoint: "compute_main"
			}
		};

		this._renderPipeline = this._device.createRenderPipeline(renderPipelineDescriptor);
		this._computePipeline = this._device.createComputePipeline(computePipelineDescriptor);
	}

	_setupBindGroups (uniformsBuffers, storageBuffers)
	{
		const bindGroupLayout = this._device.createBindGroupLayout({
			label: "bind_group_layout",
			entries: [
				{
					binding: 0,
					visibility: GPUShaderStage.VERTEX | GPUShaderStage.FRAGMENT | GPUShaderStage.COMPUTE,
					buffer: { type: "uniform" }
				},
				{
					binding: 1,
					visibility: GPUShaderStage.VERTEX | GPUShaderStage.COMPUTE,
					buffer: { type: "uniform" }
				},
				{
					binding: 2,
					visibility: GPUShaderStage.VERTEX | GPUShaderStage.FRAGMENT | GPUShaderStage.COMPUTE,
					buffer: { type: "read-only-storage" }
				},
				{
					binding: 3,
					visibility: GPUShaderStage.COMPUTE,
					buffer: { type: "storage" }
				},
				{
					binding: 4,
					visibility: GPUShaderStage.VERTEX | GPUShaderStage.FRAGMENT,
					buffer: { type: "uniform" }
				},
				{
					binding: 5,
					visibility: GPUShaderStage.VERTEX | GPUShaderStage.FRAGMENT,
					buffer: { type: "uniform" }
				},
				{
					binding: 6,
					visibility: GPUShaderStage.FRAGMENT,
					buffer: { type: "uniform" }
				}
			]
		});

		this._bindGroups = [
			this._device.createBindGroup({
				label: "bind_group_0",
				layout: bindGroupLayout,
				entries: [
					{
						binding: 0,
						resource: { buffer: uniformsBuffers.gridDimensionsBuffer }
					},
					{
						binding: 1,
						resource: { buffer: uniformsBuffers.controlDataBuffer }
					},
					{
						binding: 2,
						resource: { buffer: storageBuffers[0] }
					},
					{
						binding: 3,
						resource: { buffer: storageBuffers[1] }
					},
					{
						binding: 4,
						resource: { buffer: uniformsBuffers.viewMatrixBuffer }
					},
					{
						binding: 5,
						resource: { buffer: uniformsBuffers.projViewMatrixBuffer }
					},
					{
						binding: 6,
						resource: { buffer: uniformsBuffers.lightsBuffer }
					}
				]
			}),

			// Swapping storage buffers to swap cell states storages.
			this._device.createBindGroup({
				label: "bind_group_1",
				layout: bindGroupLayout,
				entries: [
					{
						binding: 0,
						resource: { buffer: uniformsBuffers.gridDimensionsBuffer }
					},
					{
						binding: 1,
						resource: { buffer: uniformsBuffers.controlDataBuffer }
					},
					{
						binding: 2,
						resource: { buffer: storageBuffers[1] }
					},
					{
						binding: 3,
						resource: { buffer: storageBuffers[0] }
					},
					{
						binding: 4,
						resource: { buffer: uniformsBuffers.viewMatrixBuffer }
					},
					{
						binding: 5,
						resource: { buffer: uniformsBuffers.projViewMatrixBuffer }
					},
					{
						binding: 6,
						resource: { buffer: uniformsBuffers.lightsBuffer }
					}
				]
			})
		];

		return bindGroupLayout;
	}

	_setupRenderPassDescriptor()
	{
		const clearColor = { r: 0., g: 0., b: 0., a: 1.0 };
		this._renderPassDescriptor = {
			colorAttachments: [
				{
					clearValue: clearColor,
					loadOp: "clear",
					storeOp: "store",
					// view: this._ctx.getCurrentTexture().createView(),
					view: undefined,
					resolveTarget: undefined
				}
			],

			// TODO: read more on this:
			depthStencilAttachment: {
				view: this._resolutionDependentAssets.depthTexture.createView(),
				depthClearValue: 1.0,
				depthLoadOp: "clear",
				depthStoreOp: "store"
			},
		};

		if (this._sampleCount > 1)
		{
			this._renderPassDescriptor.colorAttachments[0].view = this._resolutionDependentAssets.renderTarget.createView();
			this._renderPassDescriptor.colorAttachments[0].resolveTarget = this._ctx.getCurrentTexture().createView();
		}
		else
		{
			this._renderPassDescriptor.colorAttachments[0].view = this._ctx.getCurrentTexture().createView();
		}
	}

	_updateUniforms()
	{
		// console.log(this._controlData)
		this._device.queue.writeBuffer(this._uniformBuffers.controlDataBuffer, 0, this._controlData);
		this._device.queue.writeBuffer(this._uniformBuffers.viewMatrixBuffer, 0, this._viewMat);
		this._device.queue.writeBuffer(this._uniformBuffers.projViewMatrixBuffer, 0, this._projViewMatInv);
		this._device.queue.writeBuffer(this._uniformBuffers.lightsBuffer, 0, this._lightSource.buffer);
	}

	_updateLights(dt)
	{
		// this._lightSource.y = Math.sin(performance.now() * .001) * 2;
		this._lightSource.update();
	}

	async _copyFromStagingBuffer ()
	{
		await this._stagingBuffer.mapAsync(
			GPUMapMode.READ,
			0,
			this._stagingBuffer.size
		);

		const arrayBuffer = this._stagingBuffer.getMappedRange(0, this._stagingBuffer.size);
		const result = new Uint32Array(arrayBuffer.slice());
		this._stagingBuffer.unmap();

		return result;
	}

	async _copyHandler()
	{
		const cellStateData = await this._copyFromStagingBuffer();
		const selection = this._ui.selectionArea.getSelectionGridCorners();
		const startIdx = this._getCellIdx(selection.bottomLeft.col, selection.bottomLeft.row);
		// TODO
	}

	_pasteHandler()
	{

	}

	_renderPass(commandEncoder)
	{
		if (this._sampleCount > 1)
		{
			this._renderPassDescriptor.colorAttachments[0].view = this._resolutionDependentAssets.renderTarget.createView();
			this._renderPassDescriptor.colorAttachments[0].resolveTarget = this._ctx.getCurrentTexture().createView();
		}
		else
		{
			this._renderPassDescriptor.colorAttachments[0].view = this._ctx.getCurrentTexture().createView();
		}
		const renderPassEncoder = commandEncoder.beginRenderPass(this._renderPassDescriptor);
		renderPassEncoder.setPipeline(this._renderPipeline);
		renderPassEncoder.setVertexBuffer(0, this._vertexBuffer);
		renderPassEncoder.setIndexBuffer(this._indexBuffer, "uint32");
		renderPassEncoder.setBindGroup(0, this._bindGroups[this._simulationStep % 2]);
		// this._indexBuffer.size/4 due to uint32 - 4 bytes per index.
		renderPassEncoder.drawIndexed(this._indexBuffer.size / 4, GRID_SIZE * GRID_SIZE * GRID_SIZE);
		// renderPassEncoder.drawIndexed(this._indexBuffer.size / 4, 1);
		renderPassEncoder.end();
	}

	_computePass(commandEncoder)
	{
		this._simulationStep++;
		const computePassEncoder = commandEncoder.beginComputePass();
		computePassEncoder.setPipeline(this._computePipeline);
		computePassEncoder.setBindGroup(0, this._bindGroups[this._simulationStep % 2]);
		const workGroupCount = Math.ceil(GRID_SIZE / WORK_GROUP_SIZE);
		computePassEncoder.dispatchWorkgroups(workGroupCount, workGroupCount, workGroupCount);
		computePassEncoder.end();

		commandEncoder.copyBufferToBuffer(
			this._cellStorageBuffers[this._simulationStep % 2],
			0,
			this._stagingBuffer,
			0,
			this._stagingBuffer.size
		);
	}

	_addEventListeners()
	{
		window.addEventListener("resize", this._handleResize.bind(this));
		window.addEventListener("keydown", this._handleKeydown.bind(this));
		window.addEventListener("keyup", this._handleKeyup.bind(this));
		window.addEventListener("wheel", this._handleWheel.bind(this));
		window.addEventListener("mousemove", this._handleMouseMove.bind(this));
	}

	_updateLoop ()
	{
		requestAnimationFrame(this._updateLoopBinded);
		const dt = performance.now() - this._prevTime;
		this._frameDuration += dt;
		this._applyKeyboardInput();
		this._updateLights(dt);
		this._updateMatrices();
		this._updateUniforms();

		const commandEncoder = this._device.createCommandEncoder();

		// First render current state.
		this._renderPass(commandEncoder);

		if (this._frameDuration >= MAX_FRAME_DURATION)
		{
			// this._applyMouseInput();

			// If it's time to update make a simulationStep++ and compute next state.
			// Render it on next frame.
			this._computePass(commandEncoder);
			this._frameDuration = 0;

			// Resetting mouse buttons
			this._controlData[0] = 0;
			this._controlData[1] = 0;
			this._controlData[2] = 0;
		}

		const commandBuffer = commandEncoder.finish();
		this._device.queue.submit([commandBuffer]);
		this._prevTime = performance.now();
	}
}

window.onload = function ()
{
	var mm = new MainModule();
	mm.init();
	window.mm = mm;
}
