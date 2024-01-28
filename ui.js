const htmlByType = {
	"integer": (fieldDesc) =>
	{
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
					data-apply-on-restart="${fieldDesc.applyOnRestart || false}" />
			</label>
		</div>`
		);
	},

	"float": (fieldDesc) =>
	{
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
	}
};

export class UI
{
	constructor(cfg)
	{
		this._cfg = cfg;
		this._uiBodyDOM = undefined;
		this._handlers = {};
		this.drawing = false;
	}

	init()
	{
	}

	setUIElements(data)
	{
		const html = this._buildUIHTML(data);
		document.body.insertAdjacentHTML("beforeend", html);
		this._uiBodyDOM = document.querySelector(".ui-body");
		this._addEventListeners();
	}

	resetUIElementsStates()
	{
		const inputs = this._uiBodyDOM.querySelectorAll("input");

		for (let i = 0; i < inputs.length; i++)
		{
			inputs[i].classList.remove("restart-required");
			inputs[i].title = "";
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
		const inputField = this._uiBodyDOM.querySelector(`[name="${fieldName}"]`);
		if (inputField)
		{
			inputField.classList.add("restart-required");
			inputField.title = "RESTART REQUIRED!";
		}
	}

	_onPointermove(e)
	{
		this._runEventHandlers("pointermove", e);
	}

	_onPointerdown(e)
	{
		this.drawing = true;
		this._runEventHandlers("pointerdown", e);
	}

	_onPointerup(e)
	{
		this.drawing = false;
		this._runEventHandlers("pointerup", e);
	}

	_onKeydown(e)
	{
		if (e.key === "c" && e.ctrlKey)
		{
			console.log("ctrl+c")
			this._runEventHandlers("ctrl+c", e);
		}

		if (e.key === "v" && e.ctrlKey)
		{
			console.log("ctrl+v");
			this._runEventHandlers("ctrl+v", e);
		}

		if (e.key === "x" && e.ctrlKey)
		{
			this._runEventHandlers("ctrl+x", e);
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

	_onInput(e)
	{
		const name = e.currentTarget.name;
		const value = parseFloat(e.currentTarget.value);
		const applyOnRestart = e.currentTarget.dataset.applyOnRestart === "true";
		this._runEventHandlers("input", {name, value, applyOnRestart});
	}

	_onChange(e)
	{
		const name = e.currentTarget.name;
		const value = e.currentTarget.checked;
		this._runEventHandlers("change", {name, value});
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
		const bindedInputHandler = this._onInput.bind(this);
		const bindedChangeHandler = this._onChange.bind(this);
		const buttonClickHandler = this._onClick.bind(this);

		for (let i = 0; i < inputs.length; i++)
		{
			if (inputs[i].type === "number")
			{
				inputs[i].addEventListener("input", bindedInputHandler);
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

	_addEventListeners()
	{
		// window.addEventListener("pointerdown", (e) => { this._onPointerdown(e); });
		// window.addEventListener("pointermove", (e) => { this._onPointermove(e); });
		// window.addEventListener("pointerup", (e) => { this._onPointerup(e); });
		// window.addEventListener("keydown", this._onKeydown.bind(this));
		this._uiBodyDOM.addEventListener("mousemove", this._onMousemove);
		this._uiBodyDOM.addEventListener("mouseleave", this._onMouseleave);
		this._uiBodyDOM.addEventListener("wheel", this._stopEventPropagation);
		this._uiBodyDOM.addEventListener("keydown", this._stopEventPropagation);
		this._addInputEventListeners();
	}

	_removeEventListeners()
	{
		this._uiBodyDOM.removeEventListener("mousemove", this._onMousemove);
		this._uiBodyDOM.removeEventListener("mouseleave", this._onMouseleave);
		this._uiBodyDOM.removeEventListener("wheel", this._stopEventPropagation);
		this._uiBodyDOM.removeEventListener("keydown", this._stopEventPropagation);
	}
}
