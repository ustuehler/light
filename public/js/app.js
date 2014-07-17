var clearRegions = function () {
  $(':not(.hidden).light-region').remove();
}

var updateView = function (data) {
  var hiddenRegionDiv = $('div.light-region.hidden');
  var regionContainer = hiddenRegionDiv.parent();

  clearRegions();

  for (var region in data) {
    if (data.hasOwnProperty(region)) {
      var regionDiv = hiddenRegionDiv.clone();
      var hiddenZoneDiv = $(regionDiv).find('div.light-zone.hidden');
      var zoneContainer = $(hiddenZoneDiv).parent();

      regionDiv.attr('light-region', region);
      regionDiv.find('.light-region-title').text(region);

      for (var zone in data[region]) {
        var zoneDiv = hiddenZoneDiv.clone();
        var zoneData = data[region][zone];

        zoneDiv.attr('light-zone', zone);
        zoneDiv.find('.light-zone-title').text(zoneData['name'] || zone);

        zoneDiv.toggleClass('light-power-on', zoneData['power'] == true);
        zoneDiv.toggleClass('light-power-off', zoneData['power'] == false);
        zoneDiv.toggleClass('light-power-null', zoneData['power'] == null);

        zoneDiv.toggleClass('light-color-null', !!zoneData['color']);

        if (zoneData['color']) {
          zoneDiv.css('background-color', zoneData['color']);
        }

        zoneDiv.appendTo(zoneContainer);
        // region is still hidden
        zoneDiv.toggleClass('hidden');
      }

      hiddenZoneDiv.remove();
      regionDiv.appendTo(regionContainer);
      regionDiv.toggleClass('hidden');
    }
  }
}

var reloadData = function () {
  $.getJSON('/settings', null, function (data, textStatus, jqXHR) {
    updateView(data);
  });
}

$(reloadData);

$(document).on('click', 'div.light-zone', function (e) {
  var $this = $(this);
  var region = $this.closest('.light-region').attr('light-region');
  var zone = $this.attr('light-zone');
  var power = $this.hasClass('light-power-on');
  var postData = {};

  postData[region] = {};
  postData[region][zone] = {};
  postData[region][zone]['power'] = !power;

  $.post('/settings', JSON.stringify(postData), function (data, textStatus, jqXHR) {
    updateView(data);
  });
});

// vim: sw=2:ts=2:sts=2:expandtab
