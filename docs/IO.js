function plotCharWithColor(inputChar, xLoc, yLoc, cellForeColor, cellBackColor) {
    var oldRNG;
	
	var foreRed = cellForeColor.red,
	foreGreen = cellForeColor.green,
	foreBlue = cellForeColor.blue,
	
	backRed = cellBackColor.red,
	backGreen = cellBackColor.green,
	backBlue = cellBackColor.blue,
	
	foreRand, backRand;
	
	foreRand = rand_range(0, cellForeColor.rand);
	backRand = rand_range(0, cellBackColor.rand);
	foreRed += rand_range(0, cellForeColor.redRand) + foreRand;
	foreGreen += rand_range(0, cellForeColor.greenRand) + foreRand;
	foreBlue += rand_range(0, cellForeColor.blueRand) + foreRand;
	backRed += rand_range(0, cellBackColor.redRand) + backRand;
	backGreen += rand_range(0, cellBackColor.greenRand) + backRand;
	backBlue += rand_range(0, cellBackColor.blueRand) + backRand;
	
	foreRed =		min(100, max(0, foreRed));
	foreGreen =		min(100, max(0, foreGreen));
	foreBlue =		min(100, max(0, foreBlue));
	backRed =		min(100, max(0, backRed));
	backGreen =		min(100, max(0, backGreen));
	backBlue =		min(100, max(0, backBlue));
	
	if (inputChar != ' '
		&& foreRed		== backRed
		&& foreGreen	== backGreen
		&& foreBlue		== backBlue) {
		
		inputChar = ' ';
	}
	
	var buffer = displayBuffer.get(xLoc, yLoc);

	if (inputChar		!= buffer.character
		|| foreRed		!= buffer.foreColorComponents[0]
		|| foreGreen	!= buffer.foreColorComponents[1]
		|| foreBlue		!= buffer.foreColorComponents[2]
		|| backRed		!= buffer.backColorComponents[0]
		|| backGreen	!= buffer.backColorComponents[1]
		|| backBlue		!= buffer.backColorComponents[2]) {
		
		buffer.needsUpdate = true;
		
		buffer.character = inputChar;
		buffer.foreColorComponents[0] = foreRed;
		buffer.foreColorComponents[1] = foreGreen;
		buffer.foreColorComponents[2] = foreBlue;
		buffer.backColorComponents[0] = backRed;
		buffer.backColorComponents[1] = backGreen;
		buffer.backColorComponents[2] = backBlue;
	}
	
	//restoreRNG;
}

function commitDraws() {
	var i, j;
	
	for (i=0; i<kCOLS; i++) {
		for (j=0; j<kROWS; j++) {
			if (displayBuffer.get(i,j).needsUpdate) {
				var buffer = displayBuffer.get(i, j);

				plotChar(buffer.character, i, j,
						 buffer.foreColorComponents[0],
						 buffer.foreColorComponents[1],
						 buffer.foreColorComponents[2],
						 buffer.backColorComponents[0],
						 buffer.backColorComponents[1],
						 buffer.backColorComponents[2]);
				buffer.needsUpdate = false;
			}
		}
	}

	draw();
}

// draws overBuf over the current display with per-cell pseudotransparency as specified in overBuf.
// If previousBuf is not null, it gets filled with the preexisting display for reversion purposes.
function overlayDisplayBuffer(overBuf, previousBuf) {
	var i, j;
	var foreColor, backColor, tempColor;
	var character;
	
	if (previousBuf) {
		copyDisplayBuffer(previousBuf, displayBuffer);
	}
	
	for (i=0; i<kCOLS; i++) {
		for (j=0; j<kROWS; j++) {
			
			if (overBuf.get(i, j).opacity != 0) {
				backColor = colorFromComponents(overBuf.get(i, j).backColorComponents);
				
				// character and fore color:
				if (overBuf.get(i, j).character == ' ') { // Blank cells in the overbuf take the character from the screen.
					character = displayBuffer.get(i, j).character;
					foreColor = colorFromComponents(displayBuffer.get(i, j).foreColorComponents);
					applyColorAverage(foreColor, backColor, overBuf.get(i, j).opacity);
				} else {
					character = overBuf.get(i, j).character;
					foreColor = colorFromComponents(overBuf.get(i, j).foreColorComponents);
				}
				
				// back color:
				tempColor = colorFromComponents(displayBuffer.get(i, j).backColorComponents);
				applyColorAverage(backColor, tempColor, 100 - overBuf.get(i, j).opacity);
				
				plotCharWithColor(character, i, j, foreColor, backColor);
			}
		}
	}
}

function colorFromComponents(rgb) {
	var theColor = new Color(rgb[0], rgb[1], rgb[2]);
	return theColor;
}

function copyDisplayBuffer(toBuf, fromBuf) {
	var i, j;
	
	for (i=0; i<kCOLS; i++) {
		for (j=0; j<kROWS; j++) {
		//	toBuf[i][j] = fromBuf[i][j];
			toBuf.set(i, j, fromBuf.get(i, j));
		}
	}
};

function coordinatesAreInWindow(x, y) {
	return ((x) >= 0 && (x) < kCOLS	&& (y) >= 0 && (y) < kROWS);
} 