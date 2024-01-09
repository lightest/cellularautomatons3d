export class SelectionArea
{
	constructor(cfg)
	{
		this._cfg = cfg;
		this._selection = undefined;
		this._selectionInProgress = false;
		this._selectionAreaDOM = undefined;
	}

	init()
	{
		this._addHtml();
		this._runQuerySelectors();
		this._addEventListeners();
	}

	getSelection()
	{
		return this._selection;
	}

	_addHtml()
	{
		let html =
		`<div class="selection-area"></div>`;
		document.body.insertAdjacentHTML("beforeend", html);
	}

	_runQuerySelectors()
	{
		this._selectionAreaDOM = document.querySelector(".selection-area");
	}

	_snapToNearestCell(x, y)
	{
		const col = Math.round((x / window.innerWidth) * this._cfg.gridCols);
		const row = Math.round((y / window.innerHeight) * this._cfg.gridRows);

		return {
			x: Math.round(col * window.innerWidth / this._cfg.gridCols),
			y: Math.round(row * window.innerHeight / this._cfg.gridRows),
		};
	}

	getSelectionGridCorners()
	{
		if (!this._selection)
		{
			return undefined;
		}

		// Calculations are made assuming Y is up, so origin (0, 0) is at the bottom left of the screen.
		const blCol = Math.round((this._selection.x / window.innerWidth) * this._cfg.gridCols);
		const blRow = Math.round((1 - ((this._selection.y + this._selection.height) / window.innerHeight)) * this._cfg.gridRows);
		const trCol = Math.round(((this._selection.x + this._selection.width) / window.innerWidth) * this._cfg.gridCols) - 1;
		const trRow = Math.round((1 - (this._selection.y / window.innerHeight)) * this._cfg.gridRows) - 1;

		return {
			bottomLeft: { row: blRow, col: blCol },
			topRight: { row: trRow, col: trCol}
		};
	}

	_syncDOMWithSelection()
	{
		if (this._selection.width < 0)
		{
			this._selectionAreaDOM.style.left = `${this._selection.x + this._selection.width}px`;
			this._selectionAreaDOM.style.width = `${-this._selection.width}px`;
		}
		else
		{
			this._selectionAreaDOM.style.left = `${this._selection.x}px`;
			this._selectionAreaDOM.style.width = `${this._selection.width}px`;
		}

		if (this._selection.height < 0)
		{
			this._selectionAreaDOM.style.top = `${this._selection.y + this._selection.height}px`;
			this._selectionAreaDOM.style.height = `${-this._selection.height}px`;
		}
		else
		{
			this._selectionAreaDOM.style.top = `${this._selection.y}px`;
			this._selectionAreaDOM.style.height = `${this._selection.height}px`;
		}
	}

	_startSelection(x, y)
	{
		this._selection = {
			x,
			y,
			width: 0,
			height: 0
		};

		if (this._cfg.snapToGrid)
		{
			const newPos = this._snapToNearestCell(x, y);
			this._selection.x = newPos.x;
			this._selection.y = newPos.y;
		}

		this._syncDOMWithSelection();

		this._selectionInProgress = true;
	}

	_expandSelection(x, y)
	{
		if (this._cfg.snapToGrid)
		{
			const newPos = this._snapToNearestCell(x, y);
			x = newPos.x;
			y = newPos.y;
		}

		const width = x - this._selection.x;
		const height = y - this._selection.y;
		this._selection.width = width;
		this._selection.height = height;
		this._syncDOMWithSelection();
	}

	_finishSelection(x, y)
	{
		this._expandSelection(x, y);
		this._selectionInProgress = false;
	}

	_onPointermove(e)
	{
		if (this._selectionInProgress)
		{
			this._expandSelection(e.clientX, e.clientY);
		}
	}

	_onPointerdown(e)
	{
		this._startSelection(e.clientX, e.clientY);
	}

	_onPointerup(e)
	{
		this._finishSelection(e.clientX, e.clientY);
	}

	_addEventListeners()
	{
		window.addEventListener("pointerdown", this._onPointerdown.bind(this));
		window.addEventListener("pointermove", this._onPointermove.bind(this));
		window.addEventListener("pointerup", this._onPointerup.bind(this));
	}
}
