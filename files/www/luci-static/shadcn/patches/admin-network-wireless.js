"use strict";(function(){var boxId='p3-wifi-temperature';function translate(text){return typeof _==='function'?_(text):text;}
function getBox(){var view=document.getElementById('view');var box=document.getElementById(boxId);if(!view)
return null;if(!box){box=document.createElement('div');box.id=boxId;box.className='p3-wifi-temperature';box.hidden=true;var label=document.createElement('span');label.className='p3-wifi-temperature-label';label.textContent='WiFi '+translate('Temperature');var value=document.createElement('strong');value.className='p3-wifi-temperature-value';box.append(label,value);view.insertBefore(box,view.firstChild);}
return box;}
function refresh(fs){var box=getBox();if(!box)
return;fs.exec_direct('/sbin/tempinfo').then(function(output){var text=String(output||'').trim();var match=text.match(/(?:^|,\s*)WiFi:\s*(.+)$/);var value=match?match[1].trim():'';box.hidden=!value;if(value)
box.querySelector('.p3-wifi-temperature-value').textContent=value;}).catch(function(){box.hidden=true;});}
function start(fs){if(!getBox()){window.setTimeout(function(){start(fs);},250);return;}
refresh(fs);window.setInterval(function(){refresh(fs);},10000);}
function load(){if(!window.L||!L.require)
return;L.require('fs').then(function(fs){start(fs);}).catch(function(){});}
if(document.readyState==='loading')
document.addEventListener('DOMContentLoaded',load,{once:true});else
load();})();