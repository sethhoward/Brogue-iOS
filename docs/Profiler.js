function Profile() {
	var startTime;
	var endTime;
	var profileID = "";

	this.totalRunningTime = 0;

	this.start = function (name) {
		profileID = name;
		startTime = new Date().getTime();
	};

	this.stop = function() {
		endTime = new Date().getTime();

		this.totalRunningTime = endTime - startTime; 
	};

	this.description = function () {
		return "<" + profileID + "> total time: " + (this.totalRunningTime / 1000) + "s";
	};

	this.print = function() {
		console.log(this.description());
	}
};