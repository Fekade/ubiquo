document.observe("dom:loaded", function() {
  
  // Reloads the page when a new locale is selected from the #data-locale-selector 
  // select box
  var selector = $('data-locale-selector');
  if (selector != undefined) {
    selector.observe("change", function (event) {
      var box = Event.element(event);
      document.location.href = $F(box);
    });
  };
  
});