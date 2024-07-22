import { UI } from "./ui.js";
import * as MemoryManager from "./MemoryManager.js";
import { vec3, mat4, quat } from "./libs/wgpu-matrix.module.js";

const WORK_GROUP_SIZE = 16;
const TRANSLATION_SPEED = .15;
const MIN_TRANSLATION_SPEED_MUL = .001;
const MAX_TRANSLATION_SPEED_MUL = 100;
const NEIGHBOURS_STORAGE_LEN = 27;

// Von Neumann.
const vnNeighbourhood = new Int32Array(
	[
		1, 0, 0,  -1, 0, 0,
		0, 1, 0,  0, -1, 0,
		0, 0, 1,  0, 0, -1
	]
);

const vnNeighbourhood2D = new Int32Array(
	[
		1, 0, 0,  -1, 0, 0,
		0, 1, 0,  0, -1, 0
	]
);

// Moore.
const mooreNeighbourhood = new Int32Array(
	[
		// Middle layer, surrounding the cell.
		1, 0, 0,  -1, 0, 0,
		0, 1, 0,  0, -1, 0,
		1, 1, 0,  -1, 1, 0,
		1, -1, 0, -1, -1, 0,

		// Front layer.
		1, 0, 1,  -1, 0, 1,
		0, 1, 1,  0, -1, 1,
		1, 1, 1,  -1, 1, 1,
		1, -1, 1, -1, -1, 1,
		0, 0, 1,

		// Back layer.
		1, 0, -1,  -1, 0, -1,
		0, 1, -1,  0, -1, -1,
		1, 1, -1,  -1, 1, -1,
		1, -1, -1, -1, -1, -1,
		0, 0, -1,
	]
);

const mooreNeighbourhood2D = new Int32Array(
	[
		// Middle layer, surrounding the cell.
		1, 0, 0,  -1, 0, 0,
		0, 1, 0,  0, -1, 0,
		1, 1, 0,  -1, 1, 0,
		1, -1, 0, -1, -1, 0
	]
);

const edgesNeighbourhood = new Int32Array([
	// Above cell.
	1, 1, 0,  -1, 1, 0,
	0, 1, 1,  0, 1, -1,

	// Below cell.
	1, -1, 0,  -1, -1, 0,
	0, -1, 1,  0, -1, -1,

	// Same level as cell.
	1, 0, 1,  -1, 0, 1,
	1, 0, -1,  -1, 0, -1,
]);

const cornersNeighbourhood = new Int32Array([
	// Top corners.
	1, 1, 1,  -1, 1, 1,
	1, 1, -1,  -1, 1, -1,

	// Bottom corners.
	1, -1, 1,  -1, -1, 1,
	1, -1, -1,  -1, -1, -1,
]);

const NEIGHBOURHOOD_MAP = {
	"moore": mooreNeighbourhood,
	"moore 2D": mooreNeighbourhood2D,
	"von neumann": vnNeighbourhood,
	"von neumann 2D": vnNeighbourhood2D,
	"edges": edgesNeighbourhood,
	"corners": cornersNeighbourhood
};

class MainModule
{
	constructor()
	{
		this._ui = new UI();
		this._gridSize = 64;
		this._prevTime = performance.now();
		this._frameDuration = 0;
		this._simulationStep = 0;
		this._swapBufferIndex = 0;
		this._updateLoopBinded = this._updateLoop.bind(this);
		this._fov = 0;
		this._sampleCount = 1;
		this._viewMat = undefined;
		this._prevViewMat = undefined;
		this._inverseViewMat = undefined;
		this._projectionMat = undefined;
		this._projViewMatInv = undefined;
		this._prevProjViewMatInv = undefined;
		this._translationSpeedMul = .2;
		this._depthSamples = 35;
		this._shadowSampels = 30;
		this._cellSize = 0.85;
		this._animateLight = false;
		this._lightPositionDistance = 2;
		this._showDepthOverlay = false;
		this._computeStepDurationMS = 48; // Amount of ms to hold one frame of simulation for.
		this._neighbourhood = "von neumann";
		this._bornRulesString = "1,3";
		this._surviveRulesString = "0-6";
		// this._neighbourhood = "moore 2D";
		// this._bornRulesString = "3";
		// this._surviveRulesString = "2,3";
		this._bornRulesStringEdges = "27";
		this._surviveRulesStringEdges = "27";
		this._bornRulesStringCorners = "27";
		this._surviveRulesStringCorners = "27";
		this._totalStates = 2;
		this._randomInitialState = false;
		this._temporalAlpha = 0.1;
		this._gamma = 2;
		this._material =
		{
			roughness: .29,

			// Silver:
			// let baseSurfaceReflectivity = vec3f(0.95, 0.93, 0.88);

			// Gold:
			// let baseSurfaceReflectivity = vec3f(1.00, 0.71, 0.29);

			// Diamond:
			// let baseSurfaceReflectivity = vec3f(0.17, 0.17, 0.17);

			// Diamond base reflectivity:
			baseReflectivity: new Float32Array(3).fill(0.17),
			color: new Float32Array([0, 0, 0])
		};

		// 26 is the maximum possible amount of neighbours to consider: 9 in front of the cell, 9 in the back and 8 around.
		// 27 is to cover the last index, since 0 is also included.
		// Multiplied by 3 to cover 3 rulesets for mixed neighbourhoods mode.
		this._surviveRulesValues = new Uint32Array(NEIGHBOURS_STORAGE_LEN * 3);
		this._bornRulesValues = new Uint32Array(NEIGHBOURS_STORAGE_LEN * 3);

		this._lightSource =
		{
			// x: .5, y: 1.5, z: 1,
			x: 0.721, y: 1, z: 1,
			magnitude: 5,
			_bufferIndex: MemoryManager.allocf32(4),

			update()
			{
				MemoryManager.writef32(this._bufferIndex, this.x, this.y, this.z, this.magnitude);
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

		this._uniformBuffers = {};
		this._storageBuffers = {};
		this._cellStorageBuffers = [];
		this._resolutionDependentAssets = {};
		this._commonBindGroup = undefined;
		this._bindGroupLayouts = {};
		this._samplers = {};
		this._textureBindGroups = [];
		this._cellStatesBindGroups = [];
		this._renderTargetsSwapArray = [];
		this._depthBuffersSwapArray = [];
		this._toApplyOnSimRestart = [];

		this._buttonClickHandlers = {
			"restartSim": this._restartSim.bind(this)
		};
	}

	async init()
	{
		this._recalculateRulesValues();
		this._viewMat = mat4.lookAt(
			this._eyeVector,
			this._target,
			this._up
		);

		mat4.translate(this._viewMat, [0, 0, 1.75], this._viewMat);
		this._inverseViewMat = mat4.inverse(this._viewMat);
		this._projectionMat = mat4.create();
		this._projViewMatInv = mat4.create();
		this._prevViewMat = mat4.create();
		this._prevProjViewMatInv = mat4.create();
		this._updatePerspectiveMatrix();
		mat4.multiply(this._projectionMat, this._inverseViewMat, this._projViewMatInv);

		this._adapter = await navigator.gpu.requestAdapter({
			powerPreference: "high-performance"
		});
		this._device = await this._adapter.requestDevice();
		console.log(this._adapter, this._device);

		const pixelRatio = window.devicePixelRatio || 1.0;

		this._canvas = document.querySelector(".main-canvas");
		this._canvas.width = Math.round(window.innerWidth * pixelRatio);
		this._canvas.height = Math.round(window.innerHeight * pixelRatio);
		this._ctx = this._canvas.getContext("webgpu");
		this._ctx.configure({
			device: this._device,
			format: navigator.gpu.getPreferredCanvasFormat(),
			usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.COPY_SRC,
			alphaMode: "premultiplied"
		});
		this._createSamplers();
		this._createResolutionDependentAssests();
		// const buffers = this._getCubeVertices(.85);
		const buffers = this._getPlaneVertices();
		this._setupVertexBuffer(buffers.vertex);
		this._setupIndexBuffer(buffers.index);
		this._setupUniformsBuffers();
		this._setupStorageBuffers();
		this._setupCommonBindGroup();
		this._setupTextureResourcesBindGroups();
		this._setupCellStorageBindGroups();
		this._setupAutomatonRulesBindGroup();
		await this._setupPipelines();
		this._setupRenderPassDescriptor();
		// this._handleResize();
		console.log(this._ctx);
		this._addEventListeners();

		this._ui.init();
		this._ui.setUIElements({
			fields: [
				// {
				// 	type: "color",
				// 	label: "color",
				// 	name: "_testcolor",
				// 	value: this._testcolor,
				// 	title: "colortest"
				// },
				{
					type: "integer",
					label: "grid size",
					name: "_gridSize",
					value: this._gridSize,
					min: 3,
					max: 1024,
					title: "multiples of 32",
					applyOnRestart: true,
					customFormatter: this._gridSizeUIFormatter
				},
				{
					type: "float",
					label: "cell size",
					name: "_cellSize",
					value: this._cellSize,
					min: .01,
					max: .9
				},
				{
					type: "integer",
					label: "depth samples",
					name: "_depthSamples",
					value: this._depthSamples,
					min: 1,
					max: 500
				},
				{
					type: "integer",
					label: "shadow samples",
					name: "_shadowSampels",
					value: this._shadowSampels,
					min: 1,
					max: 256
				},
				{
					type: "float",
					label: "material roughness",
					name: "_material.roughness",
					value: this._material.roughness,
					min: 0,
					max: 1
				},
				{
					type: "color",
					format: "rgb",
					label: "base reflectivity",
					name: "_material.baseReflectivity",
					value: this._material.baseReflectivity
				},
				{
					type: "color",
					format: "rgb",
					label: "material color",
					name: "_material.color",
					value: this._material.color
				},
				{
					type: "float",
					label: "temporal reprojection alpha",
					name: "_temporalAlpha",
					value: this._temporalAlpha,
					min: 0,
					max: 1
				},
				{
					type: "float",
					label: "light magnitude",
					name: "_lightSource.magnitude",
					value: this._lightSource.magnitude,
					min: 0,
					max: 100
				},
				{
					type: "integer",
					label: "sim step duration (ms)",
					name: "_computeStepDurationMS",
					value: this._computeStepDurationMS,
					min: 16,
					max: 3000
				},
				{
					type: "boolean",
					label: "animate light",
					name: "_animateLight",
					value: this._animateLight
				},
				{
					type: "boolean",
					label: "show depth overlay",
					name: "_showDepthOverlay",
					value: this._showDepthOverlay
				},
				{
					type: "boolean",
					label: "random initial state",
					name: "_randomInitialState",
					value: this._randomInitialState
				},
				{
					type: "select",
					label: "neighbourhood",
					name: "_neighbourhood",
					options: Object.keys(NEIGHBOURHOOD_MAP),
					value: this._neighbourhood,
					applyOnRestart: true
				},
				{
					type: "text",
					label: "born rules",
					name: "_bornRulesString",
					value: this._bornRulesString,
					title: "e.g. 1,2-5,7",
					applyOnRestart: true
				},
				{
					type: "text",
					label: "survive rules",
					name: "_surviveRulesString",
					value: this._surviveRulesString,
					title: "e.g. 0-6,9",
					applyOnRestart: true
				},
				{
					type: "text",
					label: "born rules edges",
					name: "_bornRulesStringEdges",
					value: this._bornRulesStringEdges,
					title: "e.g. 1,2-5,7",
					applyOnRestart: true
				},
				{
					type: "text",
					label: "survive rules edges",
					name: "_surviveRulesStringEdges",
					value: this._surviveRulesStringEdges,
					title: "e.g. 0-6,9",
					applyOnRestart: true
				},
				{
					type: "text",
					label: "born rules corners",
					name: "_bornRulesStringCorners",
					value: this._bornRulesStringCorners,
					title: "e.g. 1,2-5,7",
					applyOnRestart: true
				},
				{
					type: "text",
					label: "survive rules corners",
					name: "_surviveRulesStringCorners",
					value: this._surviveRulesStringCorners,
					title: "e.g. 0-6,9",
					applyOnRestart: true
				},
				{
					type: "float",
					label: "1 / gamma",
					name: "_gamma",
					value: this._gamma,
					min: 1,
					max: 5
				},
				// TODO: may be for the future.
				// {
				// 	type: "text",
				// 	label: "total states",
				// 	name: "_totalStates",
				// 	value: this._totalStates,
				// 	title: "TOTAL STATES",
				// 	applyOnRestart: true
				// },
			],

			buttons: [
				{
					label: "Restart sim",
					name: "restartSim"
				}
			]
		});

		this._ui.registerHandler("input", this._onUIInput.bind(this));
		this._ui.registerHandler("change", this._onUIChange.bind(this));
		this._ui.registerHandler("button-click", this._onUIButtonClick.bind(this));

		this._setupUniformsMemoryCPU();

		this._updateLoop();
	}

	set fov(angle)
	{
		this._fov = angle * Math.PI / 180;
	}

	_setupUniformsMemoryCPU()
	{
		// To store 4 4x4 matrices.
		this._viewMatricesBufferIndex = MemoryManager.allocf32(16 * 4);
		this._windowSizeIndex = MemoryManager.allocf32(2);
		this._elapsedTimeIndex = MemoryManager.allocf32(1);
		this._depthRaySamplesIndex = MemoryManager.allocf32(1);
		this._shadowRaySamplesIndex = MemoryManager.allocf32(1);
		this._cellSizeIndex = MemoryManager.allocf32(1);
		this._showDepthOverlayIndex = MemoryManager.allocf32(1);
		this._temporalAlphaIndex = MemoryManager.allocf32(1);
		this._baseReflectivityIndex = MemoryManager.allocf32(3);
		this._roughnessIndex = MemoryManager.allocf32(1);
		this._materialColorIndex = MemoryManager.allocf32(3);
		this._gammaIndex = MemoryManager.allocf32(1);

		const pixelRatio = window.devicePixelRatio || 1.0;
		const width = Math.round(window.innerWidth * pixelRatio);
		const height = Math.round(window.innerHeight * pixelRatio);
		MemoryManager.writef32(this._windowSizeIndex, width, height);
		MemoryManager.writef32(this._depthRaySamplesIndex, this._depthSamples);
		MemoryManager.writef32(this._shadowRaySamplesIndex, this._shadowSampels);
		MemoryManager.writef32(this._cellSizeIndex, this._cellSize);
		MemoryManager.writef32(this._showDepthOverlayIndex, this._showDepthOverlay);
		MemoryManager.writef32(this._temporalAlphaIndex, this._temporalAlpha);
		MemoryManager.writef32Array(this._baseReflectivityIndex, this._material.baseReflectivity);
		MemoryManager.writef32(this._roughnessIndex, this._material.roughness);
		MemoryManager.writef32Array(this._materialColorIndex, this._material.color);
		MemoryManager.writef32(this._gammaIndex, this._gamma);
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

		// TODO: is there a more elegant way to calc these?
		const prevViewMatOffset = this._viewMat.length + this._projViewMatInv.length;
		const prevProjeViewMatInvOffset = this._viewMat.length + this._projViewMatInv.length + this._prevViewMat.length;

		// prevFrame matrices are updated at the end of the frame, after render, but we write them here for immediate availability to GPU.
		MemoryManager.writef32Array(this._viewMatricesBufferIndex, this._viewMat);
		MemoryManager.writef32Array(this._viewMatricesBufferIndex + this._viewMat.length, this._projViewMatInv);
		MemoryManager.writef32Array(this._viewMatricesBufferIndex + prevViewMatOffset, this._prevViewMat);
		MemoryManager.writef32Array(this._viewMatricesBufferIndex + prevProjeViewMatInvOffset, this._prevProjViewMatInv);
	}

	_updatePrevMatrices()
	{
		mat4.copy(this._viewMat, this._prevViewMat);
		mat4.copy(this._projViewMatInv, this._prevProjViewMatInv);
	}

	_setValue(name = "", value = 0)
	{
		const nameComponents = name.split(".");
		let valueAcceptor = this;

		// Reach the end of nested value and stop right before last one.
		for (let i = 0; i < nameComponents.length - 1; i++)
		{
			valueAcceptor = valueAcceptor[nameComponents[i]];
		}

		if (valueAcceptor[nameComponents[nameComponents.length - 1]] !== undefined)
		{
			// Last one will be value itself, set it.
			if (typeof value === "object" && value.length !== undefined)
			{
				for (let i = 0; i < value.length; i++)
				{
					valueAcceptor[nameComponents[nameComponents.length - 1]][i] = value[i];
				}
			}
			else
			{
				valueAcceptor[nameComponents[nameComponents.length - 1]] = value;
			}
		}
	}

	_rulesComponentsToValues(rulesComponents)
	{
		const result = [];
		rulesComponents = rulesComponents.replaceAll(" ", "");
		const components = rulesComponents.split(",");
		for (let i = 0; i < components.length; i++)
		{
			if (components[i].indexOf("-") > -1)
			{
				const range = components[i].split("-");
				const start = parseInt(range[0], 10);
				const end = parseInt(range[1], 10);

				for (let j = start; j <= end; j++)
				{
					result.push(Math.min(j, 26));
				}
			}
			else
			{
				result.push(
					Math.min(parseInt(components[i], 10), 26)
				);
			}
		}

		return result;
	}

	_recalculateRulesValues()
	{
		// Contains arrays of born and survival neighbours amounts.
		// For instance "1, 3" for born rules will result in array [1, 3],
		// "0-6" will result in [0, 1, 2, 3, 4, 5, 6] - these arrays are elements of rulesets[].
		const rulesets = [
			this._rulesComponentsToValues(this._bornRulesString),
			this._rulesComponentsToValues(this._surviveRulesString),
			this._rulesComponentsToValues(this._bornRulesStringEdges),
			this._rulesComponentsToValues(this._surviveRulesStringEdges),
			this._rulesComponentsToValues(this._bornRulesStringCorners),
			this._rulesComponentsToValues(this._surviveRulesStringCorners),
		];

		let offset = 0;
		this._bornRulesValues.fill(0);
		this._surviveRulesValues.fill(0);

		for (let i = 0; i < rulesets.length; i += 2)
		{
			const bornValues = rulesets[i];
			const surviveValues = rulesets[i + 1];

			for (let j = 0; j < bornValues.length; j++)
			{
				this._bornRulesValues[bornValues[j] + offset] = 1;
			}

			for (let j = 0; j < surviveValues.length; j++)
			{
				this._surviveRulesValues[surviveValues[j] + offset] = 1;
			}

			offset += NEIGHBOURS_STORAGE_LEN;
		}


		console.log(rulesets, this._totalStates);
		console.log(this._surviveRulesValues, this._bornRulesValues);
	}

	_restartSim()
	{
		for (let i = 0; i < this._toApplyOnSimRestart.length; i++)
		{
			const data = this._toApplyOnSimRestart[i];
			this._setValue(data.name, data.value);
		}
		this._simulationStep = 0;
		this._frameDuration = 0;
		this._recalculateRulesValues();
		this._resetStorageBuffers();
		this._device.queue.writeBuffer(this._uniformBuffers.gridDimensionsBuffer, 0, new Float32Array([this._gridSize, this._gridSize, this._gridSize]));
		this._ui.resetUIElementsStates();
	}

	_onUIInput(e)
	{
		if (e.applyOnRestart)
		{
			this._ui.markSimRestartRequired(e.name);
			this._toApplyOnSimRestart.push(e);
		}
		else
		{
			this._setValue(e.name, e.value);
		}
	}

	// TODO: replace?
	_onUIChange(e)
	{
		if (e.applyOnRestart)
		{
			this._ui.markSimRestartRequired(e.name);
			this._toApplyOnSimRestart.push(e);
		}
		else
		{
			this._setValue(e.name, e.value);
		}
	}

	_onUIButtonClick(e)
	{
		if (typeof this._buttonClickHandlers[e.name] === "function")
		{
			this._buttonClickHandlers[e.name](e);
		}
	}

	// Round to the closest multiples of 32.
	_gridSizeUIFormatter(v)
	{
		let out = v;
		let vMod32 = v % 32;

		if (vMod32 > 0)
		{
			if (vMod32 <= 16)
			{
				out = v - vMod32;
			}
			else
			{
				out = v - vMod32 + 32;
			}
		}

		return out;
	}

	async _getShaderSources()
	{
		let vertexSrc = await fetch("./shaders/pathtraced_vertex.wgsl");
		vertexSrc = await vertexSrc.text();
		let fragmentSrc = await fetch("./shaders/pathtraced_fragment_clustered.wgsl");
		fragmentSrc = await fragmentSrc.text();

		return {
			vertexSrc,
			fragmentSrc
		};
	}

	async _getComputeShaderSources ()
	{
		// let computeSrc = await fetch("./shaders/compute.wgsl");
		let computeSrc = await fetch("./shaders/compute_clustered.wgsl");
		computeSrc = await computeSrc.text();

		return computeSrc;
	}

	_createSamplers()
	{
		const prevFrameSampler = this._device.createSampler({
			magFilter: "nearest",
			minFilter: "nearest"
		});

		this._samplers = {
			prevFrameSampler
		};
	}

	_createResolutionDependentAssests()
	{
		const pixelRatio = window.devicePixelRatio || 1;
		const width = Math.round(window.innerWidth * pixelRatio);
		const height = Math.round(window.innerHeight * pixelRatio);

		for (let i in this._resolutionDependentAssets)
		{
			this._resolutionDependentAssets[i].destroy();
		}

		const renderTarget0 = this._device.createTexture({
			size: [width, height],
			sampleCount: this._sampleCount,
			// format: navigator.gpu.getPreferredCanvasFormat(),
			format: "rgba16float",
			usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.TEXTURE_BINDING
		});

		const renderTarget1 = this._device.createTexture({
			size: [width, height],
			sampleCount: this._sampleCount,
			// format: navigator.gpu.getPreferredCanvasFormat(),
			format: "rgba16float",
			usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.TEXTURE_BINDING
		});

		const depthBuffer0 = this._device.createTexture({
			size: [width, height],
			sampleCount: this._sampleCount,
			format: "rg16float",
			usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.TEXTURE_BINDING
		});

		const depthBuffer1 = this._device.createTexture({
			size: [width, height],
			sampleCount: this._sampleCount,
			format: "rg16float",
			usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.TEXTURE_BINDING
		});

		this._renderTargetsSwapArray = [renderTarget0, renderTarget1];
		this._depthBuffersSwapArray = [depthBuffer0, depthBuffer1];

		this._resolutionDependentAssets = {
			renderTarget0,
			renderTarget1,
			depthBuffer0,
			depthBuffer1
		};
	}

	_handleResize()
	{
		const pixelRatio = window.devicePixelRatio || 1.0;
		const width = Math.round(window.innerWidth * pixelRatio);
		const height = Math.round(window.innerHeight * pixelRatio);
		if (this._canvas.width !== width || this._canvas.height !== height)
		{
			this._canvas.width = width;
			this._canvas.height = height;
		}

		MemoryManager.writef32(this._windowSizeIndex, width, height);

		this._createResolutionDependentAssests();
		this._setupTextureResourcesBindGroups();
		this._updatePerspectiveMatrix();
	}

	_handleWheel(e)
	{
		const translationMul = this._translationSpeedMul * Math.sign(-e.deltaY) * .1;
		this._translationSpeedMul = Math.max(
			MIN_TRANSLATION_SPEED_MUL,
			Math.min(this._translationSpeedMul + translationMul, MAX_TRANSLATION_SPEED_MUL)
		);
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

	_handleCanvasPointerdown(e)
	{
		this._canvas.requestPointerLock();
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
			1, 1, 0, 1,	// vertex
			0, 0, 1,	// normal
			1, 1,		// uv
			-1, -1, 0, 1,
			0, 0, 1,
			0, 0,
			1, -1, 0, 1,
			0, 0, 1,
			1, 0,
			-1, 1, 0, 1,
			0, 0, 1,
			0, 1
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
		const vertices = new Float32Array([
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
		// const vertices = new Float32Array([
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
			vertex: vertices,
			index: indices
		};
	}

	_setupVertexBuffer(data)
	{
		if (this._vertexBuffer)
		{
			this._vertexBuffer.destroy();
		}

		this._vertexBuffer = this._device.createBuffer({
			size: data.byteLength,
			usage: GPUBufferUsage.VERTEX | GPUBufferUsage.COPY_DST
		});
		const bufferWriteStartIdx = 0
		this._device.queue.writeBuffer(this._vertexBuffer, bufferWriteStartIdx, data);
	}

	_getCellIdx (x, y)
	{
		if (x < 0)
		{
			x = this._gridSize + x;
		}
		if (y < 0)
		{
			y = this._gridSize + y;
		}
		return (x % this._gridSize) + (y % this._gridSize) * this._gridSize;
	}

	_getCellIdx3D(x, y, z)
	{
		const xGridSize = this._gridSize / 32;
		x /= 32;
		if (x < 0)
		{
			x = xGridSize + x;
		}
		if (y < 0)
		{
			y = this._gridSize + y;
		}
		if (z < 0)
		{
			z = this._gridSize + z;
		}
		return (x % xGridSize) + (y % this._gridSize) * xGridSize + (z % this._gridSize) * xGridSize * this._gridSize;
	}

	_getClusterIdxFromGridCoordinates(cellCoords)
	{
		// Dividing by 32 because we use uint32 clusters (cells) in the array.
		const cols = this._gridSize / 32;
		const layerSize = cols * this._gridSize;
		const x = Math.floor(cellCoords.x / 32);

		return (x % cols) + (cellCoords.y % this._gridSize) * cols + (cellCoords.z % this._gridSize) * layerSize;
	}

	_setupIndexBuffer(data)
	{
		if (this._indexBuffer)
		{
			this._indexBuffer.destroy();
		}

		this._indexBuffer = this._device.createBuffer({
			size: data.byteLength,
			usage: GPUBufferUsage.INDEX | GPUBufferUsage.COPY_DST
		});

		const bufferWriteStartIdx = 0;
		this._device.queue.writeBuffer(this._indexBuffer, bufferWriteStartIdx, data);
	}

	_setupUniformsBuffers ()
	{
		for (let i in this._uniformBuffers)
		{
			this._uniformBuffers[i].destroy();
		}

		// TODO: Should these be unified into a singular uniforms buffer?
		const gridDimensionsData = new Float32Array([this._gridSize, this._gridSize, this._gridSize]);
		const gridDimensionsBuffer = this._device.createBuffer({
			label: "grid uniforms",
			size: gridDimensionsData.byteLength,
			usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST
		});

		const commonFrequentBuffer = this._device.createBuffer({
			label: "common buffer f32",
			size: MemoryManager.bufferf32.byteLength,
			usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST
		});

		this._device.queue.writeBuffer(gridDimensionsBuffer, 0, gridDimensionsData);
		this._device.queue.writeBuffer(commonFrequentBuffer, 0, MemoryManager.bufferf32.buffer);

		this._uniformBuffers = {
			gridDimensionsBuffer,
			commonFrequentBuffer
		};

		return this._uniformBuffers;
	}

	_setupStorageBuffers ()
	{
		for (let i = 0; i < this._cellStorageBuffers.length; i++)
		{
			this._cellStorageBuffers[i].destroy();
		}

		for (let i in this._storageBuffers)
		{
			this._storageBuffers[i].destroy();
		}

		// Dividing by 32 since we store data as bits within uint32 cells.
		const cellStateData = new Uint32Array((this._gridSize / 32) * this._gridSize * this._gridSize);

		if (this._randomInitialState)
		{
			const center = Math.floor(this._gridSize * .5) - 1;
			let i, j, k;
			for (i = -2; i < 3; i++)
			{
				for (j = -2; j < 3; j++)
				{
					for (k = -2; k < 3; k++)
					{
						const idx = this._getClusterIdxFromGridCoordinates({
							x: center + i,
							y: center + j,
							z: center + k
						});
						// const offset = Math.floor(Math.random() * 32);
						const v = Math.random() > .5;
						if (v)
						{
							cellStateData[idx] = cellStateData[idx] | (1 << center + i);
						}
						else
						{
							cellStateData[idx] = cellStateData[idx] & ~(1 << center + i);
						}
					}
				}
			}

			// Random seed 5x5.

			// Random overall.
			// for (i = 0; i < cellStateData.length; i++)
			// {
			// 	cellStateData[i] = Math.random() > .957;
			// }
		}
		else
		{
			// 2,6,9/4,6,8-9/2
			// Sets initial state.
			// const center = Math.floor(this._gridSize * .5);
			// cellStateData[this._getCellIdx3D(center, center, center)] = 1;

			const idx = this._getClusterIdxFromGridCoordinates({
				x: Math.floor(this._gridSize * .5) - 1,
				y: Math.floor(this._gridSize * .5) - 1,
				z: Math.floor(this._gridSize * .5) - 1
			});

			const offset = (Math.floor(this._gridSize * 0.5) - 1) % 32;
			console.log("MID INDEX", idx);
			cellStateData[idx] = 1 << offset;
			// cellStateData[16] = 65535;
			console.log("INITIAL DATA", cellStateData);

			// TODO: add setCellState function.
			// Glider.
			// cellStateData[this._getCellIdx3D(x, y + 1, z)] = 1 << 31;
			// cellStateData[this._getCellIdx3D(x, y - 1, z)] = 1 << 31;
			// cellStateData[this._getCellIdx3D(x + 1, y, z)] = 1;
			// cellStateData[this._getCellIdx3D(x + 1, y - 1, z)] = 1;
			// cellStateData[this._getCellIdx3D(x - 1, y - 1, z)] = 1 << 30;

			// cellStateData[this._getCellIdx3D(x, y + 1, z)] = 1 << 31;
			// cellStateData[this._getCellIdx3D(x, y - 1, z)] = 3 << 30;
			// cellStateData[idx + 1] = 1;
			// cellStateData[this._getCellIdx3D(x, y - 1, z) + 1] = 1;
			// cellStateData[this._getCellIdx3D(x, y - 1, z)] = 1 << 30;
		}

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

		const neighbourhoodOffsets = NEIGHBOURHOOD_MAP[this._neighbourhood];

		const neighbourhoodBuffer = this._device.createBuffer({
			label: "neighbourhood buffer",
			size: neighbourhoodOffsets.byteLength,
			usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST
		});

		const surviveRulesBuffer = this._device.createBuffer({
			label: "survive rules buffer",
			size: this._surviveRulesValues.byteLength,
			usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST
		});

		const bornRulesBuffer = this._device.createBuffer({
			label: "born rules buffer",
			size: this._bornRulesValues.byteLength,
			usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST
		});

		// Mixed neighbourhood rules mode.
		const edgesNeighbourhoodBuffer = this._device.createBuffer({
			label: "edges neighbourhood buffer",
			size: edgesNeighbourhood.byteLength,
			usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST
		});

		const cornersNeighbourhoodBuffer = this._device.createBuffer({
			label: "corners neighbourhood buffer",
			size: cornersNeighbourhood.byteLength,
			usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST
		});

		this._device.queue.writeBuffer(cellStorageBuffers[0], 0, cellStateData);
		this._device.queue.writeBuffer(cellStorageBuffers[1], 0, cellStateData);
		this._device.queue.writeBuffer(neighbourhoodBuffer, 0, neighbourhoodOffsets);
		this._device.queue.writeBuffer(surviveRulesBuffer, 0, this._surviveRulesValues);
		this._device.queue.writeBuffer(bornRulesBuffer, 0, this._bornRulesValues);

		// Additional set of neighbourhood for mixed neighbours mode.
		this._device.queue.writeBuffer(edgesNeighbourhoodBuffer, 0, edgesNeighbourhood);
		this._device.queue.writeBuffer(cornersNeighbourhoodBuffer, 0, cornersNeighbourhood);

		// TODO: unify?
		this._cellStorageBuffers = cellStorageBuffers;
		this._storageBuffers = {
			neighbourhoodBuffer,
			edgesNeighbourhoodBuffer,
			cornersNeighbourhoodBuffer,
			surviveRulesBuffer,
			bornRulesBuffer,
		};

		return cellStorageBuffers;
	}

	_resetStorageBuffers()
	{
		this._setupStorageBuffers();
		this._setupCellStorageBindGroups();
		this._setupAutomatonRulesBindGroup();
	}

	async _setupPipelines()
	{
		// TODO: Should this be a separate func?
		const shaderSources = await this._getShaderSources();
		const computeShaderSources = await this._getComputeShaderSources();

		const vertexShaderModule = this._device.createShaderModule({ code: shaderSources.vertexSrc });
		const fragmentShaderModule = this._device.createShaderModule({ code: shaderSources.fragmentSrc });
		const computeShaderModule = this._device.createShaderModule({ code: computeShaderSources });

		const renderPipelineLayout = this._device.createPipelineLayout({
			bindGroupLayouts: [
				this._bindGroupLayouts.mainLayout,
				this._bindGroupLayouts.samplersBindGroupLayout,
				this._bindGroupLayouts.cellStorageBindGroupLayout
			]
		});

		const buffersLayout = [
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
					},
					{
						shaderLocation: 2,
						offset: 28,
						format: "float32x2"
					}
				],
				arrayStride: 36, // bytes
				stepMode: "vertex"
			}
		];

		const renderPipelineDescriptor = {
			vertex: {
				module: vertexShaderModule,
				entryPoint: "vertex_main",
				buffers: buffersLayout,
			},

			fragment: {
				module: fragmentShaderModule,
				entryPoint: "fragment_main",
				targets: [
					{
						format: navigator.gpu.getPreferredCanvasFormat()
					},
					{
						format: "rgba16float"
					},
					{
						format: "rg16float"
					}
				]
			},

			primitive: {
				topology: "triangle-list",
				cullMode: "back"
			},

			layout: renderPipelineLayout,

			multisample: {
				count: this._sampleCount
			},
		};

		const computePipelineDescriptor =
		{
			layout: this._device.createPipelineLayout({
				bindGroupLayouts:
				[
					this._bindGroupLayouts.mainLayout,
					this._bindGroupLayouts.cellStorageBindGroupLayout,
					this._bindGroupLayouts.automatonRulesLayout
				]
			}),
			compute: {
				module: computeShaderModule,
				entryPoint: "compute_main"
			}
		};

		this._renderPipeline = this._device.createRenderPipeline(renderPipelineDescriptor);
		this._computePipeline = this._device.createComputePipeline(computePipelineDescriptor);
	}

	_setupTextureResourcesBindGroups()
	{
		const samplersBindGroupLayout = this._device.createBindGroupLayout({
			label: "samplers_bind_group_layout",
			entries: [
				{
					binding: 0,
					visibility: GPUShaderStage.FRAGMENT,
					texture: {
						sampleType: "float"
					}
				},
				{
					binding: 1,
					visibility: GPUShaderStage.FRAGMENT,
					texture: {
						sampleType: "float"
					}
				},
				{
					binding: 2,
					visibility: GPUShaderStage.FRAGMENT,
					sampler: { type: "filtering" }
				}
			]
		});

		this._bindGroupLayouts.samplersBindGroupLayout = samplersBindGroupLayout;

		// For samplerBindGroups we user reverse order for binded renderTargets.
		// First binding 1, then 0, because on first frame renderTarget0 is the output, renderTarget1 is input.
		this._textureBindGroups[0] = this._device.createBindGroup({
			label: "samplers_bind_group",
			layout: samplersBindGroupLayout,
			entries: [
				{
					binding: 0,
					resource: this._resolutionDependentAssets.renderTarget1.createView()
				},
				{
					binding: 1,
					resource: this._resolutionDependentAssets.depthBuffer1.createView()
				},
				{
					binding: 2,
					resource: this._samplers.prevFrameSampler
				}
			]
		});

		this._textureBindGroups[1] = this._device.createBindGroup({
			label: "samplers_bind_group",
			layout: samplersBindGroupLayout,
			entries: [
				{
					binding: 0,
					resource: this._resolutionDependentAssets.renderTarget0.createView()
				},
				{
					binding: 1,
					resource: this._resolutionDependentAssets.depthBuffer0.createView()
				},
				{
					binding: 2,
					resource: this._samplers.prevFrameSampler
				}
			]
		});
	}

	_setupCellStorageBindGroups()
	{
		const storageBuffers = this._cellStorageBuffers;

		const cellStorageBindGroupLayout = this._device.createBindGroupLayout({
			label: "cell storage bindgroup layout",
			entries: [
				{
					binding: 0,
					visibility: GPUShaderStage.VERTEX | GPUShaderStage.FRAGMENT | GPUShaderStage.COMPUTE,
					buffer: { type: "read-only-storage" }
				},
				{
					binding: 1,
					visibility: GPUShaderStage.COMPUTE,
					buffer: { type: "storage" }
				}
			]
		});

		this._bindGroupLayouts.cellStorageBindGroupLayout = cellStorageBindGroupLayout;

		this._cellStatesBindGroups[0] = this._device.createBindGroup({
			label: "cell storage bindgroup 0",
			layout: cellStorageBindGroupLayout,
			entries: [
				{
					binding: 0,
					resource: { buffer: storageBuffers[0] }
				},
				{
					binding: 1,
					resource: { buffer: storageBuffers[1] }
				}
			]
		});

		// Cell storage bind group used for swapping, note alterated storageBuffers[] indices.
		this._cellStatesBindGroups[1] = this._device.createBindGroup({
			label: "cell storage bindgroup 1",
			layout: cellStorageBindGroupLayout,
			entries: [
				{
					binding: 0,
					resource: { buffer: storageBuffers[1] }
				},
				{
					binding: 1,
					resource: { buffer: storageBuffers[0] }
				}
			]
		});
	}

	_setupAutomatonRulesBindGroup()
	{
		const automatonRulesLayout = this._device.createBindGroupLayout({
			label: "automaton_rules_layout",
			entries: [
				{
					binding: 0,
					visibility: GPUShaderStage.COMPUTE,
					buffer: { type: "read-only-storage" }
				},
				{
					binding: 1,
					visibility: GPUShaderStage.COMPUTE,
					buffer: { type: "read-only-storage" }
				},
				{
					binding: 2,
					visibility: GPUShaderStage.COMPUTE,
					buffer: { type: "read-only-storage" }
				},
				{
					binding: 3,
					visibility: GPUShaderStage.COMPUTE,
					buffer: { type: "read-only-storage" }
				},
				{
					binding: 4,
					visibility: GPUShaderStage.COMPUTE,
					buffer: { type: "read-only-storage" }
				},
			]
		});

		this._bindGroupLayouts.automatonRulesLayout = automatonRulesLayout;

		this._automatonRulesBindGroup = this._device.createBindGroup({
			label: "automatons_bind_group",
			layout: automatonRulesLayout,
			entries: [
				{
					binding: 0,
					resource: { buffer: this._storageBuffers.neighbourhoodBuffer }
				},
				{
					binding: 1,
					resource: { buffer: this._storageBuffers.edgesNeighbourhoodBuffer }
				},
				{
					binding: 2,
					resource: { buffer: this._storageBuffers.cornersNeighbourhoodBuffer }
				},

				{
					binding: 3,
					resource: { buffer: this._storageBuffers.surviveRulesBuffer }
				},
				{
					binding: 4,
					resource: { buffer: this._storageBuffers.bornRulesBuffer }
				},
			]
		});
	}

	_setupCommonBindGroup ()
	{
		const uniformBuffers = this._uniformBuffers;

		const mainLayout = this._device.createBindGroupLayout({
			label: "main_bind_group_layout",
			entries: [
				{
					binding: 0,
					visibility: GPUShaderStage.VERTEX | GPUShaderStage.FRAGMENT | GPUShaderStage.COMPUTE,
					buffer: { type: "uniform" }
				},
				{
					binding: 11,
					visibility: GPUShaderStage.VERTEX | GPUShaderStage.FRAGMENT,
					buffer: { type: "uniform" }
				}
			]
		});

		this._bindGroupLayouts.mainLayout = mainLayout;

		this._commonBindGroup = this._device.createBindGroup({
			label: "bind_group_0",
			layout: mainLayout,
			entries: [
				{
					binding: 0,
					resource: { buffer: uniformBuffers.gridDimensionsBuffer }
				},
				{
					binding: 11,
					resource: { buffer: uniformBuffers.commonFrequentBuffer }
				}
			]
		});
	}

	_setupRenderPassDescriptor()
	{
		const clearColor = { r: 0., g: 0., b: 0., a: 1.0 };
		this._renderPassDescriptor = {
			colorAttachments: [
				// Screen output
				{
					clearValue: clearColor,
					loadOp: "clear",
					storeOp: "store",
					view: undefined,
					resolveTarget: undefined
				},

				// Screen buffer
				{
					view: undefined,
					loadOp: "clear",
					storeOp: "store",
					clearValue: clearColor
				},

				// Depth buffer
				{
					view: undefined,
					loadOp: "clear",
					storeOp: "store",
					clearValue: clearColor
				}
			],
		};
	}

	_updateUniforms()
	{
		this._device.queue.writeBuffer(this._uniformBuffers.commonFrequentBuffer, 0, MemoryManager.bufferf32.buffer);
	}

	_updateLights(dt)
	{
		if (this._animateLight)
		{
			this._lightSource.y = Math.sin(performance.now() * .0007) * this._lightPositionDistance;
			this._lightSource.x = Math.cos(performance.now() * .0007) * this._lightPositionDistance;
		}
		this._lightSource.update();
	}

	_updateUIValues()
	{
		MemoryManager.writef32(this._depthRaySamplesIndex, this._depthSamples);
		MemoryManager.writef32(this._shadowRaySamplesIndex, this._shadowSampels);
		MemoryManager.writef32(this._cellSizeIndex, this._cellSize);
		MemoryManager.writef32(this._showDepthOverlayIndex, this._showDepthOverlay);
		MemoryManager.writef32(this._temporalAlphaIndex, this._temporalAlpha);
		MemoryManager.writef32Array(this._baseReflectivityIndex, this._material.baseReflectivity);
		MemoryManager.writef32(this._roughnessIndex, this._material.roughness);
		MemoryManager.writef32Array(this._materialColorIndex, this._material.color);
		MemoryManager.writef32(this._gammaIndex, this._gamma);
	}

	_renderPass(commandEncoder)
	{
		// TODO: should we store created views somewhere instead?
		this._renderPassDescriptor.colorAttachments[0].view = this._ctx.getCurrentTexture().createView();
		this._renderPassDescriptor.colorAttachments[1].view = this._renderTargetsSwapArray[this._swapBufferIndex].createView();
		this._renderPassDescriptor.colorAttachments[2].view = this._depthBuffersSwapArray[this._swapBufferIndex].createView();

		const renderPassEncoder = commandEncoder.beginRenderPass(this._renderPassDescriptor);
		renderPassEncoder.setPipeline(this._renderPipeline);
		renderPassEncoder.setVertexBuffer(0, this._vertexBuffer);
		renderPassEncoder.setIndexBuffer(this._indexBuffer, "uint32");
		renderPassEncoder.setBindGroup(0, this._commonBindGroup);
		renderPassEncoder.setBindGroup(1, this._textureBindGroups[this._swapBufferIndex]);
		renderPassEncoder.setBindGroup(2, this._cellStatesBindGroups[this._simulationStep % 2]);

		// this._indexBuffer.size/4 due to uint32 - 4 bytes per index.
		renderPassEncoder.drawIndexed(this._indexBuffer.size / 4, 1);
		renderPassEncoder.end();
		this._swapBufferIndex = (this._swapBufferIndex + 1) % 2;
	}

	_computePass(commandEncoder)
	{
		const computePassEncoder = commandEncoder.beginComputePass();
		computePassEncoder.setPipeline(this._computePipeline);
		computePassEncoder.setBindGroup(0, this._commonBindGroup);
		computePassEncoder.setBindGroup(1, this._cellStatesBindGroups[this._simulationStep % 2]);
		computePassEncoder.setBindGroup(2, this._automatonRulesBindGroup);

		// TODO: ensure to validate workGroupCount with this._adapter.limits.
		const workGroupCount = Math.ceil(this._gridSize / WORK_GROUP_SIZE);
		computePassEncoder.dispatchWorkgroups(this._gridSize / 32, workGroupCount, workGroupCount);
		computePassEncoder.end();
		this._simulationStep++;
	}

	_addEventListeners()
	{
		window.addEventListener("resize", this._handleResize.bind(this));
		window.addEventListener("keydown", this._handleKeydown.bind(this));
		window.addEventListener("keyup", this._handleKeyup.bind(this));
		window.addEventListener("wheel", this._handleWheel.bind(this));
		window.addEventListener("mousemove", this._handleMouseMove.bind(this));
		this._canvas.addEventListener("pointerdown", this._handleCanvasPointerdown.bind(this));
	}

	_updateLoop ()
	{
		requestAnimationFrame(this._updateLoopBinded);
		const dt = performance.now() - this._prevTime;
		this._frameDuration += dt;
		MemoryManager.writef32(this._elapsedTimeIndex, performance.now() * .0001);
		this._applyKeyboardInput();
		this._updateLights(dt);
		this._updateMatrices();
		this._updateUIValues();
		this._updateUniforms();

		const commandEncoder = this._device.createCommandEncoder();

		// First render current state.
		this._renderPass(commandEncoder);

		if (this._frameDuration >= this._computeStepDurationMS)
		{
			// this._applyMouseInput();

			// If it's time to update make a simulationStep++ and compute next state.
			// Rendering of cell storage will happen on next frame.
			// This way we ensure we can see initial state, set before computations.
			this._computePass(commandEncoder);
			this._frameDuration = 0;
		}

		const commandBuffer = commandEncoder.finish();
		this._device.queue.submit([commandBuffer]);

		this._updatePrevMatrices();
		this._prevTime = performance.now();
	}
}

window.onload = function ()
{
	var mm = new MainModule();
	mm.init();
	window.mm = mm;
}
