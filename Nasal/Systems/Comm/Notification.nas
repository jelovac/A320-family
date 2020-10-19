# A3XX Notification System
# Jonathan Redpath

# Copyright (c) 2020 Josh Davidson (Octal450)
var defaultServer = "https://www.aviationweather.gov/adds/dataserver_current/httpparam?dataSource=metars&requestType=retrieve&format=xml&mostRecent=true&hoursBeforeNow=12&stationString=";
var serverString = "";
var result = nil;

var ATSU = {
	working: 0,
	loop: func() {
		if (systems.ELEC.Bus.ac1.getValue() >= 110 or systems.ELEC.Bus.dc1.getValue() >= 25) {
			me.working = 1;
		} else {
			me.working = 0;
		}
	}
};

var notificationSystem = {
	notifyAirport: nil,
	hasNotified: 0,
	inputAirport: func(airport) {
		if (!fmgc.FMGCInternal.flightNumSet or size(airport) != 4) { return 1; }
		var airportList = findAirportsByICAO(airport);
		if (size(airportList) == 0) { return 2; }
		if (me.hasNotified) { me.hasNotified = 0; }
		me.notifyAirport = airportList[0].id;
		return 0;
	},
	notify: func() {
		if (me.notifyAirport != nil) {
			me.hasNotified = 1;
			# todo - send notification to ATC
			return 0;
		} else {
			return 1;
		}
	},
	automaticTransfer: func(station) {
		var airportList = findAirportsByICAO(station);
		if (size(airportList) == 0) { return 2; }
		me.notifyAirport = airportList[0].id;
		return 0;
	},
};

var ADS = {
	state: 1,
	connections: [nil, nil, nil, nil],
	setState: func(state) {
		me.state = state;
	},
	getCount: func() {
		var count = 0;
		for (var i = 0; i < 4; i = i + 1) {
			if (me.connections[i] != nil) {
				count += 1;
			}
		}
		return count;
	},
};

var CompanyCall = {
	activeMsg: "",
	frequency: 999.99,
	received: 0,
	tuned: 0,
	init: func() {
		me.activeMsg = "";
		me.frequency = 999.99;
		me.received = 0;
	},
	newMsg: func(msg, freq) {
		me.activeMsg = msg;
		me.frequency = freq;
		me.received = 0;
	},
	ack: func() {
		me.received = 1;
		## assume that call remains until you receive another one or aircraft is reset
	},
	tune: func() {
		if (!me.received) { me.ack(); }
		if (rmp.act_vhf3.getValue() == 0) { 
			for (var i = 0; i < 3; i = i + 1) {
				if (getprop("/systems/radio/rmp[" ~ i ~ "]/sel_chan") == "vhf3") {
					setprop("/systems/radio/rmp[" ~ i ~ "]/vhf3-standby", me.frequency);
					rmp.transfer(i + 1);
					me.tuned = 1;
				}
			}
		}
	},
};

var AOC = {
	station: nil,
	selectedType: "HOURLY WX",
	lastMETAR: nil,
	lastTAF: nil,
	sent: 0,
	sentTime: nil,
	received: 0,
	receivedTime: nil,
	server: 0, # 0 = noaa, 1 = vatsim
	newStation: func(airport) {
		if (size(airport) == 3 or size(airport) == 4) {
			if (size(findAirportsByICAO(airport)) == 0) {
				return 2;
			} else {
				me.station = airport;
				return 0;
			}
		} else {
			return 1;
		}
	},
	sendReq: func(i) {
		if (me.station == nil or (me.sent and !me.received)) {
			return 1;
		}
		me.sent = 1;
		me.received = 0;
		var sentTime = left(getprop("/sim/time/gmt-string"), 5);
		me.sentTime = split(":", sentTime)[0] ~ "." ~ split(":", sentTime)[1] ~ "Z";
		
		if (me.selectedType == "HOURLY WX") {
			var result = me.fetchMETAR(atsu.AOC.station, i);
			if (result == 0) {
				return 0;
			} elsif (result == 1) {
				return 3;
			} elsif (result == 2) {
				return 4;
			}
		}
		
		if (me.selectedType == "TERM FCST") {
			var result = me.fetchTAF(atsu.AOC.station, i); 
			if (result == 0) {
				return 0;
			} elsif (result == 1) {
				return 3;
			} elsif (result == 2) {
				return 4;
			}
		}
	},
	fetchMETAR: func(airport, i) {
		if (!ATSU.working) {
			me.sent = 0;
			return 2;
		}
		if (ecam.vhf3_voice.active) {
			me.sent = 0;
			return 1;
		}
		
		serverString = "";
		
		if (me.server == 0) {
			serverString = defaultServer;
		} elsif (me.server == 1) {
			serverString = "https://api.flybywiresim.com/metar?source=vatsim&icao=";
		} else { # fall back to NOAA silently
			serverString = defaultServer;
		}
		
		http.load(serverString ~ airport)
			.fail(func(r) print("Download failed; try changing your server to NOAA"))
			.done(func(r) me.processMETAR(r, i));
		return 0;
	},
	fetchTAF: func(airport, i) {
		if (!ATSU.working) {
			me.sent = 0;
			return 2;
		}
		if (ecam.vhf3_voice.active) {
			me.sent = 0;
			return 1;
		}
		http.load("https://www.aviationweather.gov/adds/dataserver_current/httpparam?dataSource=tafs&requestType=retrieve&format=xml&timeType=issue&mostRecent=true&hoursBeforeNow=12&stationString=" ~ airport)
			.fail(func print("Download failed!"))
			.done(func(r) me.processTAF(r, i));
		return 0;
	},
	processMETAR: func(r, i) {
		var raw = r.response;
		raw = split("<raw_text>", raw)[1];
		raw = split("</raw_text>", raw)[0];
		me.lastMETAR = raw;
		settimer(func() {
			me.received = 1;
			mcdu.mcdu_message(i, "WX UPLINK");
			
			var receivedTime = left(getprop("/sim/time/gmt-string"), 5);
			me.receivedTime = split(":", receivedTime)[0] ~ "." ~ split(":", receivedTime)[1] ~ "Z";
			var message = mcdu.ACARSMessage.new(me.receivedTime, me.lastMETAR);
			mcdu.ReceivedMessagesDatabase.addMessage(message);
		}, math.max(rand()*6, 2.25));
	},
	processTAF: func(r, i) {
		var raw = r.response;
		raw = split("<raw_text>", raw)[1];
		raw = split("</raw_text>", raw)[0];
		me.lastTAF = raw;
		settimer(func() {
			me.received = 1;
			mcdu.mcdu_message(i, "WX UPLINK");
			
			var receivedTime = left(getprop("/sim/time/gmt-string"), 5);
			me.receivedTime = split(":", receivedTime)[0] ~ "." ~ split(":", receivedTime)[1] ~ "Z";
			var message = mcdu.ACARSMessage.new(me.receivedTime, me.lastTAF);
			mcdu.ReceivedMessagesDatabase.addMessage(message);
		}, math.max(rand()*6, 2.25));
	},
};

var ATIS = {
	station: nil,
	lastATIS: nil,
	sent: 0,
	sentTime: nil,
	received: 0,
	receivedTime: nil,
	server: 0,
	newStation: func(airport) {
		if (size(airport) == 3 or size(airport) == 4) {
			if (size(findAirportsByICAO(airport)) == 0) {
				return 2;
			} else {
				me.station = airport;
				return 0;
			}
		} else {
			return 1;
		}
	},
	sendReq: func(i) {
		if (me.station == nil or (me.sent and !me.received)) {
			return 1;
		}
		me.sent = 1;
		me.received = 0;
		var sentTime = left(getprop("/sim/time/gmt-string"), 5);
		me.sentTime = split(":", sentTime)[0] ~ "." ~ split(":", sentTime)[1] ~ "Z";
		
		result = me.fetchATIS(atsu.ATIS.station, i);
		if (result == 0) {
			return 0;
		} elsif (result == 1) {
			return 3;
		} elsif (result == 2) {
			return 4;
		}
	},
	fetchATIS: func(airport, i) {
		if (!ATSU.working) {
			me.sent = 0;
			return 2;
		}
		if (ecam.vhf3_voice.active) {
			me.sent = 0;
			return 1;
		}
		
		serverString = "";
		
		if (me.server == 0) {
			serverString = "https://api.flybywiresim.com/atis?source=faa&icao=";
		} elsif (me.server == 1) {
			serverString = "https://api.flybywiresim.com/atis?source=vatsim&icao=";
		} else { # fall back to FAA silently
			serverString = "https://api.flybywiresim.com/atis?source=faa&icao=";
		}
		
		http.load(serverString ~ airport)
			.fail(func(r) return 3)
			.done(func(r) me.processATIS(r, i));
		return 0;
	},
	processATIS: func(r, i) {
		var raw = r.response;
		if (find("combined", raw)) {
			raw = split('{"combined":"', raw)[1];
			raw = split('"}', raw)[0];
		} else {
			raw = split('{"arr":"', raw)[1];
			raw = split('","dep":', raw)[0];
		}
		me.lastATIS = raw;
		settimer(func() {
			me.received = 1;
			mcdu.mcdu_message(i, "WX UPLINK");
			
			var receivedTime = left(getprop("/sim/time/gmt-string"), 5);
			me.receivedTime = split(":", receivedTime)[0] ~ "." ~ split(":", receivedTime)[1] ~ "Z";
			var message = mcdu.ACARSMessage.new(me.receivedTime, me.lastATIS);
			mcdu.ReceivedMessagesDatabase.addMessage(message);
		}, math.max(rand()*10, 2.25));
	},
};