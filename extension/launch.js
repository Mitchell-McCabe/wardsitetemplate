chrome.action.onClicked.addListener(async()=>{
  const url=chrome.runtime.getURL('preview.html');
  const [open]=await chrome.tabs.query({url});
  if(open){await chrome.tabs.update(open.id,{active:true});await chrome.windows.update(open.windowId,{focused:true});}
  else await chrome.tabs.create({url});
});
