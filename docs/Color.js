function Color(red, green, blue, redRand, greenRand, blueRand, rand, colorDances ) {
	this.red = red;
	this.green = green;
	this.blue = blue;

	// extra components for random color distribution (namely for Brogue demo)
	// random rGB components to add to base components
	if (typeof(redRand) === 'undefined') {
		this.redRand = 0;
	}
	else {
		this.redRand = redRand;
	}

	if (typeof(greenRand) === 'undefined') {
		this.greenRand = 0;
	}
	else {
		this.greenRand = greenRand;
	}

	if (typeof(blueRand) === 'undefined') {
		this.blueRand = 0;
	}
	else {
		this.blueRand = blueRand;
	}

	if (typeof(rand) === 'undefined') {
		this.rand = 0;
	}
	else {
		this.rand = rand;
	}

	if (typeof(colorDances) === 'undefined') {
		this.colorDances = 0;
	}
	else {
		this.colorDances = colorDances;
	}
}

Color.prototype.rgbaStyle = function () {
	return "rgba(" + this.red + ", " + this.green + ", " + this.blue + ", 1)";
};

Color.prototype.rgbHexValue = function () {
	return rgbToHex(this.red, this.green, this.blue);
};

Color.prototype.rgbToHex = function(r, g, b) {
	return "#" + ((1 << 24) + (r << 16) + (g << 8) + b).toString(16).slice(1);
};

Color.prototype.description = function () {
	return ("<Color> r: " + this.red + " g: " + this.green + " b: " + this.blue);
};