(function (root) {
  let assetsPromise;
  function script(src) {
    return new Promise((resolve, reject) => {
      const element = document.createElement('script'); element.src = src;
      element.onload = resolve; element.onerror = () => { element.remove(); reject(new Error('Could not load the PDF tools. Please try again.')); };
      document.head.appendChild(element);
    });
  }
  async function assets() {
    if (!assetsPromise) assetsPromise = (async () => {
      await Promise.all([root.PDFLib ? null : script('vendor/pdf-lib-1.17.1.min.js'), root.fontkit ? null : script('vendor/fontkit-1.1.1.min.js')]);
      const fonts = await Promise.all(['vendor/DejaVuSans.ttf', 'vendor/DejaVuSans-Bold.ttf'].map(async url => {
        const r = await fetch(url); if (!r.ok) throw new Error('Could not load the print fonts. Please try again.'); return new Uint8Array(await r.arrayBuffer());
      }));
      return { PDFLib: root.PDFLib, fontkit: root.fontkit, regular: fonts[0], bold: fonts[1] };
    })().catch(error => { assetsPromise = null; throw error; });
    return assetsPromise;
  }
  const parseDate = value => new Date(value + 'T12:00:00Z');
  function rangeDates(start, end) {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(start) || !/^\d{4}-\d{2}-\d{2}$/.test(end)) throw new Error('Choose the start and end dates.');
    const first = parseDate(start), last = parseDate(end);
    if (!Number.isFinite(+first) || !Number.isFinite(+last) || first.toISOString().slice(0, 10) !== start || last.toISOString().slice(0, 10) !== end || end < start) throw new Error('Choose a valid date range.');
    if ((last - first) / 86400000 > 365) throw new Error('Choose a date range of one year or less.');
    return { first, last };
  }
  async function build(data, providedAssets) {
    rangeDates(data.start, data.end);
    const a = providedAssets || await assets(), { PDFDocument, rgb } = a.PDFLib;
    const pdf = await PDFDocument.create(); pdf.registerFontkit(a.fontkit);
    const regular = await pdf.embedFont(a.regular, { subset: true }), bold = await pdf.embedFont(a.bold, { subset: true });
    const characters = new Set(regular.getCharacterSet());
    const safe = value => Array.from(String(value ?? '').replace(/\r\n?/g, '\n').replace(/\t/g, ' ')).map(c => c === '\n' || characters.has(c.codePointAt(0)) ? c : '?').join('');
    const ink = rgb(.11, .16, .23), muted = rgb(.36, .39, .42), line = rgb(.73, .75, .76), off = rgb(.94, .94, .94);
    const width = 792, height = 612, margin = 30;
    const dateLabel = value => parseDate(value).toLocaleDateString('en-US', { timeZone: 'UTC', month: 'short', day: 'numeric', year: 'numeric' });
    const range = dateLabel(data.start) + ' - ' + dateLabel(data.end);
    const bookings = (data.bookings || []).filter(r => r.status === 'booked' && r.meal_date >= data.start && r.meal_date <= data.end).sort((x,y) => x.meal_date.localeCompare(y.meal_date));
    const byDate = new Map(bookings.map(r => [r.meal_date, r]));
    const blocked = new Set((data.blocked || []).map(r => typeof r === 'string' ? r : r.meal_date));
    const text = (page, value, x, top, size = 10, font = regular, color = ink) => page.drawText(safe(value), { x, y: height - top - size, size, font, color });
    function wrap(value, maxWidth, size, font = regular) {
      const result = [];
      for (const paragraph of safe(value).split('\n')) {
        let current = '';
        for (const word of paragraph.split(/\s+/).filter(Boolean)) {
          if (font.widthOfTextAtSize(current ? current + ' ' + word : word, size) <= maxWidth) { current = current ? current + ' ' + word : word; continue; }
          if (current) { result.push(current); current = ''; }
          for (const c of word) {
            if (current && font.widthOfTextAtSize(current + c, size) > maxWidth) { result.push(current); current = ''; }
            current += c;
          }
        }
        result.push(current);
      }
      return result;
    }
    function limitedLines(value, maxWidth, size, count, font = regular) {
      const lines = wrap(value, maxWidth, size, font);
      if (lines.length > count) {
        lines.length = count;
        while (lines[count-1] && font.widthOfTextAtSize(lines[count-1] + '...', size) > maxWidth) lines[count-1] = lines[count-1].slice(0,-1);
        lines[count-1] += '...';
      }
      return lines;
    }
    function header(page, title, subtitle) {
      text(page, limitedLines(data.wardName || 'Your Ward', width - margin * 2, 11, 1, bold)[0], margin, 24, 11, bold);
      text(page, title, margin, 43, 21, bold);
      text(page, (data.missionaries || 'Missionaries') + '  |  ' + subtitle, margin, 75, 10, regular, muted);
    }
    const months = [];
    for (let month = data.start.slice(0,7); month <= data.end.slice(0,7);) {
      months.push(month); const [y,m] = month.split('-').map(Number); month = m === 12 ? (y+1)+'-01' : y+'-'+String(m+1).padStart(2,'0');
    }
    for (const month of months) {
      const page = pdf.addPage([width,height]), [year,m] = month.split('-').map(Number);
      header(page, 'Missionary meal calendar', range);
      text(page, new Date(Date.UTC(year,m-1,1)).toLocaleDateString('en-US', { timeZone:'UTC', month:'long',year:'numeric' }), margin, 99, 15, bold);
      const first = new Date(Date.UTC(year,m-1,1)).getUTCDay(), days = new Date(Date.UTC(year,m,0)).getUTCDate();
      const rows = Math.ceil((first+days)/7), cellW = (width-margin*2)/7, cellH = 388/rows, top = 143;
      ['Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday'].forEach((day,i) => text(page,day,margin+i*cellW+7,124,9,bold));
      for (let n=0;n<rows*7;n++) {
        const day=n-first+1, x=margin+(n%7)*cellW, y=top+Math.floor(n/7)*cellH;
        const date=month+'-'+String(day).padStart(2,'0'), inRange=day>0 && day<=days && date>=data.start && date<=data.end;
        const booking=inRange ? byDate.get(date) : null, unavailable=inRange && blocked.has(date);
        page.drawRectangle({x,y:height-y-cellH,width:cellW,height:cellH,borderWidth:.5,borderColor:line,color:!inRange || unavailable ? off : rgb(1,1,1)});
        if(day<1 || day>days)continue;
        text(page,String(day),x+7,y+5,10,bold,inRange?ink:rgb(.65,.65,.65));
        if(!inRange)continue;
        if(booking) {
          const name=limitedLines(booking.name,cellW-14,8.5,2,bold);
          name.forEach((v,i)=>text(page,v,x+7,y+21+i*10,8.5,bold));
          const phone=limitedLines(booking.phone,cellW-14,8,1)[0];
          text(page,phone,x+7,y+23+name.length*10,8);
          text(page,'See appointment details',x+7,y+cellH-13,6.5,regular,muted);
        } else text(page,unavailable?'Unavailable':(data.bookingEnd && date>data.bookingEnd?'Not open yet':'Open'),x+7,y+25,9,regular,muted);
      }
      text(page,bookings.length?'Full names, phone numbers, and notes are on the appointment-detail pages.':'No meal appointments are booked in this date range.',margin,549,9,regular,muted);
    }
    if (bookings.length) {
      let page, y;
      function detailsPage() {
        page=pdf.addPage([width,height]);header(page,'Meal appointment details',range);
        page.drawRectangle({x:margin,y:height-115,width:width-margin*2,height:22,color:rgb(.92,.94,.95)});
        text(page,'Date',margin+8,98,10,bold);text(page,'Household / phone',margin+114,98,10,bold);text(page,'Notes',margin+324,98,10,bold);y=115;
      }
      detailsPage();
      for(const row of bookings) {
        const name=wrap(String(row.name).replace(/\s+/g,' '),190,10,bold), phone=wrap(String(row.phone).replace(/\s+/g,' '),190,10), notes=wrap(row.notes||'-',width-margin*2-340,10);
        const date=[parseDate(row.meal_date).toLocaleDateString('en-US',{timeZone:'UTC',weekday:'short'}),dateLabel(row.meal_date)];
        for(let offset=0;offset<notes.length;offset+=28) {
          const part=notes.slice(offset,offset+28), dateLines=offset?date.concat('Continued'):date;
          const h=Math.max(dateLines.length,name.length+phone.length,part.length)*13+20;
          if(y+h>558)detailsPage();
          page.drawRectangle({x:margin,y:height-y-h,width:width-margin*2,height:h,borderWidth:.5,borderColor:line});
          dateLines.forEach((v,i)=>text(page,v,margin+8,y+9+i*13,9));
          name.forEach((v,i)=>text(page,v,margin+114,y+9+i*13,10,bold));
          phone.forEach((v,i)=>text(page,v,margin+114,y+9+(name.length+i)*13,10));
          part.forEach((v,i)=>text(page,v,margin+324,y+9+i*13,10));
          y+=h;
        }
      }
    }
    const pages=pdf.getPages();
    pages.forEach((page,i)=>{
      text(page,'Generated '+new Date().toLocaleDateString('en-US',{timeZone:data.timeZone||'America/New_York'}),margin,582,8,regular,muted);
      text(page,'Page '+(i+1)+' of '+pages.length,width-margin-65,582,8,regular,muted);
    });
    pdf.setTitle('Missionary meals - '+range); pdf.setAuthor(data.wardName||'Ward Site');
    return pdf.save();
  }
  function download(bytes,start,end) {
    const blob=new Blob([bytes],{type:'application/pdf'}),url=URL.createObjectURL(blob);
    const link=document.createElement('a');link.href=url;link.download='missionary-meals-'+start+'-to-'+end+'.pdf';document.body.appendChild(link);link.click();link.remove();setTimeout(()=>URL.revokeObjectURL(url),60000);
  }
  const api={build,download,rangeDates};
  root.NPMealPdf=api;
  if(typeof module!=='undefined' && module.exports)module.exports=api;
})(typeof window!=='undefined'?window:globalThis);
