// Church Member List PDFs are parsed on the leader's device, never uploaded.
export function parseMemberPages(pages) {
 const members=[];let ward='',expected=null;
 for(const items of pages){
  const lines=[];
  for(const item of items){if(!item.str?.trim())continue;const y=item.transform[5];let line=lines.find(l=>Math.abs(l.y-y)<2);if(!line){line={y,items:[]};lines.push(line);}line.items.push(item);}
  lines.sort((a,b)=>b.y-a.y);for(const line of lines){line.items.sort((a,b)=>a.transform[4]-b.transform[4]);line.text=line.items.map(i=>i.str.trim()).join(' ');}
  const header=lines.find(l=>l.items.some(i=>/^Name$/i.test(i.str.trim())));
  if(!header)throw Error('This PDF does not have the expected Member List columns. Use the Church member-list printout or a CSV export.');
  const phoneHeader=header.items.find(i=>/^Phone(?: Number)?$/i.test(i.str.trim()));
  const phoneX=phoneHeader?.transform[4];
  for(const line of lines){
   const count=line.text.match(/^Count:\s*(\d+)/i);if(count){expected=Number(count[1]);continue;}
   if(line.y>header.y&&/\b(?:Ward|Branch)\b/i.test(line.text))ward=line.text;
   if(line.y>=header.y||line.y<45||/For Church Use Only|Intellectual Reserve|All rights reserved/i.test(line.text))continue;
   const nameItems=line.items.filter(i=>phoneX==null||i.transform[4]<phoneX-10);
   const name=nameItems.map(i=>i.str.trim()).join(' ').trim();
   const phone=phoneX==null?'':line.items.filter(i=>i.transform[4]>=phoneX-10).map(i=>i.str.trim()).join(' ').trim();
   if(!name||/^Count:|^Name$/i.test(name))continue;
   if(name.length<2||/\d/.test(name))throw Error('An unexpected row was found. Please use the original member-list PDF or a CSV export.');
   if(phone&&!/^\+?[\d\s().\-–]+(?:\s*(?:x|ext\.?)\s*\d+)?$/i.test(phone))throw Error('A phone number could not be read reliably. Please use the original PDF or a CSV export.');
   members.push([name,phone]);
  }
 }
 if(!members.length)throw Error('No member names were found. Scanned photos are not supported; upload the PDF saved from the print menu.');
 if(expected!==null&&expected!==members.length)throw Error('The PDF lists '+expected+' members, but '+members.length+' were read. No members were imported. Try exporting the PDF again or use CSV.');
 if(members.length>3000)throw Error('Import up to 3000 members at a time.');
 return {headers:['Full name','Phone'],rows:members,pdf:true,ward,expected};
}
export async function readMemberPdf(data,onProgress=()=>{}){
 const pdfjs=await import('./vendor/pdfjs/pdf.min.mjs');
 pdfjs.GlobalWorkerOptions.workerSrc=new URL('./vendor/pdfjs/pdf.worker.min.mjs',import.meta.url).href;
 const task=pdfjs.getDocument({data,isEvalSupported:false,useSystemFonts:true});let doc;
 try{doc=await task.promise;if(doc.numPages>100)throw Error('Choose a member list with no more than 100 pages.');const pages=[];
  for(let n=1;n<=doc.numPages;n++){onProgress(n,doc.numPages);const page=await doc.getPage(n);pages.push((await page.getTextContent()).items);page.cleanup();}
  return parseMemberPages(pages);
 }finally{await task.destroy();}
}
