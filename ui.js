function RGBToHex(rgb = [])
{
	// Convert each channel to integer
	const r = Math.round(rgb[0] * 255);
	const g = Math.round(rgb[1] * 255);
	const b = Math.round(rgb[2] * 255);

	// Convert to hexadecimal format
	return "#" + ((1 << 24) + (r << 16) + (g << 8) + b).toString(16).slice(1);
}

function hexToRgb(hex = "") {
    // Remove '#' if present
    hex = hex.replace(/^#/, '');

    // Parse hexadecimal string to integers
    let bigint = parseInt(hex, 16);

    // Extract RGB components
    let r = (bigint >> 16) & 255;
    let g = (bigint >> 8) & 255;
    let b = bigint & 255;

    // Convert to range 0-1 and return as Float32Array
    return new Float32Array([r / 255, g / 255, b / 255]);
}


const htmlByType = {
	"integer": (fieldDesc) =>
	{
		const title = fieldDesc.title || `${fieldDesc.min || 0} to ${fieldDesc.max || 10}`;

		return(
		`<div class="ui-input">
			<label><div class="caption">${fieldDesc.label}:</div>
				<input
					type="number"
					name="${fieldDesc.name}"
					value="${fieldDesc.value}"
					step="1"
					min="${fieldDesc.min || 0}"
					max="${fieldDesc.max || 10}"
					title="${title}"
					data-apply-on-restart="${fieldDesc.applyOnRestart || false}" />
			</label>
		</div>`
		);
	},

	"float": (fieldDesc) =>
	{
		const title = fieldDesc.title || `${fieldDesc.min || 0} to ${fieldDesc.max || 10}`;

		return(
		`<div class="ui-input">
			<label><div class="caption">${fieldDesc.label}:</div>
				<input
					type="number"
					name="${fieldDesc.name}"
					value="${fieldDesc.value}"
					step="0.01"
					min="${fieldDesc.min || 0}"
					max="${fieldDesc.max || 1}"
					title="${title}"
					data-apply-on-restart="${fieldDesc.applyOnRestart || false}" />
			</label>
		</div>`
		);
	},

	"floatArray": (fieldDesc) =>
	{
		let fieldsHTML = "";

		for (let i = 0; i < fieldDesc.value.length; i++)
		{
			fieldsHTML +=
			`<input
				type="number"
				name="${fieldDesc.name}"
				value="${fieldDesc.value[i]}"
				step="0.01"
				min="${fieldDesc.min || 0}"
				max="${fieldDesc.max || 1}"/>`
		}

		return(
		`<div class="ui-input">
			<label><div class="caption">${fieldDesc.label}:</div>
				${fieldsHTML}
			</label>
		</div>`
		);
	},

	"boolean": (fieldDesc) =>
	{
		return(
			`<div class="ui-input">
				<label><div class="caption">${fieldDesc.label}:</div>
					<input type="checkbox" name="${fieldDesc.name}" ${fieldDesc.value ? "checked" : ""} />
				</label>
			</div>`
		);
	},

	"select": (fieldDesc) =>
	{
		const optionsHTML = (fieldDesc.options.map(
			o => `<option value="${o}" ${o === fieldDesc.value ? "selected" : ""} >${o}</option>`
		)).join("");

		return (
			`<div class="ui-input">
				<label><div class="caption">${fieldDesc.label}:</div>
					<select name="${fieldDesc.name}"
					data-apply-on-restart="${fieldDesc.applyOnRestart || false}" >
					${optionsHTML}</select>
				</label>
			</div>`
		);
	},

	"text": (fieldDesc) =>
	{
		return(
			`<div class="ui-input">
				<label><div class="caption">${fieldDesc.label}:</div>
					<input
						type="text"
						name="${fieldDesc.name}"
						value="${fieldDesc.value}"
						title="${fieldDesc.title || ""}"
						data-apply-on-restart="${fieldDesc.applyOnRestart || false}" />
				</label>
			</div>`
		);
	},

	"color": (fieldDesc) =>
	{
		const value = (typeof fieldDesc.value === "object" && fieldDesc.value.length !== undefined) ?
		RGBToHex(fieldDesc.value) : fieldDesc.value;
		return(
			`<div class="ui-input">
				<label><div class="caption">${fieldDesc.label}:</div>
					<input
						type="color"
						name="${fieldDesc.name}"
						value="${value}"
						title="${fieldDesc.title || ""}"
						data-apply-on-restart="${fieldDesc.applyOnRestart || false}" />
				</label>
			</div>`
		);
	}
};

export class UI
{
	constructor(cfg)
	{
		this._cfg = cfg;
		this._uiElements = {};
		this._lutByName = {};
		this._uiBodyDOM = undefined;
		this._handlers = {};
		this.drawing = false;
	}

	init()
	{
	}

	setUIElements(data)
	{
		this._uiElements = data;
		this._generateLUTByName(data);
		const html = this._buildUIHTML(data);
		document.body.insertAdjacentHTML("beforeend", html);
		this._uiBodyDOM = document.querySelector(".ui-body");
		this._addEventListeners();
	}

	resetUIElementsStates()
	{
		const inputs = this._uiBodyDOM.querySelectorAll("input");
		const selects = this._uiBodyDOM.querySelectorAll("select");

		for (let i = 0; i < inputs.length; i++)
		{
			inputs[i].classList.remove("restart-required");
			if (inputs[i].type === "number")
			{
				inputs[i].title = `${inputs[i].min} to ${inputs[i].max}`;
			}
			else
			{
				const existingFieldDesc = this._lutByName[inputs[i].name];
				if (existingFieldDesc)
				{
					inputs[i].title = existingFieldDesc.title || "";
				}
				else
				{
					inputs[i].title = "";
				}
			}
		}

		for (let i = 0; i < selects.length; i++)
		{
			selects[i].classList.remove("restart-required");
			selects[i].title = "";
		}
	}

	registerHandler(e, handler)
	{
		if (typeof handler !== "function")
		{
			console.error("Passed handler isn't a function!");
			return;
		}

		if (this._handlers[e] === undefined)
		{
			this._handlers[e] = [];
		}

		this._handlers[e].push(handler);
	}

	_buildUIHTML(data)
	{
		const { fields, buttons } = data;
		const addedFieldsByNameMap = {};

		let fieldsHTML = "";
		let buttonsHTML = "";

		for (let i = 0; i < fields.length; i++)
		{
			const fieldDesc = fields[i];

			if (addedFieldsByNameMap[fieldDesc.name] !== undefined)
			{
				console.warn(`Field with name "fieldDesc.name" already added, skipping.`);
				continue;
			}

			if (htmlByType[fieldDesc.type])
			{
				fieldsHTML += htmlByType[fieldDesc.type](fieldDesc);
				addedFieldsByNameMap[fieldDesc.name] = 1;
			}
			else
			{
				console.warn("No html generator for type", fieldDesc.type);
			}
		}

		for (let i = 0; i < buttons.length; i++)
		{
			const buttonDesc = buttons[i];
			buttonsHTML += `<div class="ui-button" data-name="${buttonDesc.name}">${buttonDesc.label}</div>`
		}

		let html =
		`<div class="ui-container">
			<div class="ui-body">
				${fieldsHTML}
				<div class="buttons-container">
					${buttonsHTML}
				</div>
			</div>
		</div>`;

		return html;
	}

	_generateLUTByName(data)
	{
		const lut = {};

		for (let i = 0; i < data.fields.length; i++)
		{
			lut[data.fields[i].name] = data.fields[i];
		}

		this._lutByName = lut;
	}

	_runEventHandlers(e, data)
	{
		if (this._handlers[e] instanceof Array)
		{
			for (let i = 0; i < this._handlers[e].length; i++)
			{
				this._handlers[e][i](data);
			}
		}
	}

	markSimRestartRequired(fieldName)
	{
		const uiField = this._uiBodyDOM.querySelector(`[name="${fieldName}"]`);
		if (uiField)
		{
			uiField.classList.add("restart-required");
			uiField.title = "RESTART SIM REQUIRED!";
		}
	}

	_onMousemove(e)
	{
		const bcr = e.currentTarget.getBoundingClientRect();
		const x = ((e.clientX - bcr.x) / bcr.width) * 2. - 1.;
		const y = ((e.clientY - bcr.y) / bcr.height) * 2. - 1.;
		e.currentTarget.style.transform = `perspective(1000px) rotateX(${y * 5}deg) rotateY(${-x * 5}deg)`;
	}

	_onMouseleave(e)
	{
		e.currentTarget.style.transform = `perspective(1000px) rotateX(0deg) rotateY(0deg)`;
	}

	_stopEventPropagation(e)
	{
		e.stopPropagation();
	}

	_onNumericInput(e)
	{
		const name = e.currentTarget.name;
		const min = parseFloat(e.currentTarget.min);
		const max = parseFloat(e.currentTarget.max);
		const fieldDesc = this._lutByName[name];
		let parsedVal = parseFloat(e.currentTarget.value);
		let value = min;

		if (!Number.isNaN(parsedVal))
		{
			value = Math.min(max, Math.max(min, parsedVal));
		}

		if (fieldDesc.customFormatter !== undefined)
		{
			value =	fieldDesc.customFormatter(value);
		}

		const applyOnRestart = e.currentTarget.dataset.applyOnRestart === "true";
		this._runEventHandlers("input", {name, value, applyOnRestart});
	}

	_onNumericChange(e)
	{
		const min = parseFloat(e.currentTarget.min);
		const max = parseFloat(e.currentTarget.max);
		const name = e.currentTarget.name;
		const fieldDesc = this._lutByName[name];
		let parsedVal = parseFloat(e.currentTarget.value);
		let value = min;

		if (!Number.isNaN(parsedVal))
		{
			value = Math.min(max, Math.max(min, parsedVal));
		}

		if (fieldDesc.customFormatter !== undefined)
		{
			value =	fieldDesc.customFormatter(value);
		}

		e.currentTarget.value = value;
	}

	_onTextInput(e)
	{
		const name = e.currentTarget.name;
		const value = e.currentTarget.value;
		const applyOnRestart = e.currentTarget.dataset.applyOnRestart === "true";
		this._runEventHandlers("input", { name, value, applyOnRestart });
	}

	_onColorInput(e)
	{
		const name = e.currentTarget.name;
		const fieldDesc = this._lutByName[name];
		const value = fieldDesc.format === "rgb" ? hexToRgb(e.currentTarget.value) : e.currentTarget.value;
		const applyOnRestart = e.currentTarget.dataset.applyOnRestart === "true";
		this._runEventHandlers("input", { name, value, applyOnRestart });
	}

	_onCheckboxChange(e)
	{
		const name = e.currentTarget.name;
		const value = e.currentTarget.checked;
		this._runEventHandlers("change", {name, value});
	}

	_onSelectChange(e)
	{
		const name = e.currentTarget.name;
		const value = e.currentTarget.value;
		const applyOnRestart = e.currentTarget.dataset.applyOnRestart === "true";
		this._runEventHandlers("change", {name, value, applyOnRestart});
	}

	_onClick(e)
	{
		const name = e.currentTarget.dataset.name;
		this._runEventHandlers("button-click", {name});
	}

	_addInputEventListeners()
	{
		const inputs = this._uiBodyDOM.querySelectorAll("input");
		const buttons = this._uiBodyDOM.querySelectorAll(".ui-button");
		const bindedNumericInputHandler = this._onNumericInput.bind(this);
		const bindedNumericChangeHandler = this._onNumericChange.bind(this);
		const bindedTextInputHandler = this._onTextInput.bind(this);
		const bindedColorInputHandler = this._onColorInput.bind(this);
		const bindedChangeHandler = this._onCheckboxChange.bind(this);
		const buttonClickHandler = this._onClick.bind(this);

		for (let i = 0; i < inputs.length; i++)
		{
			if (inputs[i].type === "number")
			{
				inputs[i].addEventListener("input", bindedNumericInputHandler);
				inputs[i].addEventListener("change", bindedNumericChangeHandler);
			}
			else if (inputs[i].type === "text")
			{
				inputs[i].addEventListener("input", bindedTextInputHandler);
			}
			else if (inputs[i].type === "color")
			{
				inputs[i].addEventListener("input", bindedColorInputHandler);
			}
			else if (inputs[i].type === "checkbox")
			{
				inputs[i].addEventListener("change", bindedChangeHandler);
			}
		}

		for (let i = 0; i < buttons.length; i++)
		{
			buttons[i].addEventListener("click", buttonClickHandler);
		}
	}

	_addSelectEventListeners()
	{
		const selects = this._uiBodyDOM.querySelectorAll("select");
		const bindedSelectChangeHandler = this._onSelectChange.bind(this);

		for (let i = 0; i < selects.length; i++)
		{
			selects[i].addEventListener("change", bindedSelectChangeHandler);
		}
	}

	_addEventListeners()
	{
		this._uiBodyDOM.addEventListener("mousemove", this._onMousemove);
		this._uiBodyDOM.addEventListener("mouseleave", this._onMouseleave);
		this._uiBodyDOM.addEventListener("wheel", this._stopEventPropagation);
		this._uiBodyDOM.addEventListener("keydown", this._stopEventPropagation);
		this._addInputEventListeners();
		this._addSelectEventListeners();
	}

	_removeEventListeners()
	{
		this._uiBodyDOM.removeEventListener("mousemove", this._onMousemove);
		this._uiBodyDOM.removeEventListener("mouseleave", this._onMouseleave);
		this._uiBodyDOM.removeEventListener("wheel", this._stopEventPropagation);
		this._uiBodyDOM.removeEventListener("keydown", this._stopEventPropagation);
	}
}
