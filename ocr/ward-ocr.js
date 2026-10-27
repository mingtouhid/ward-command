/* Ward Sync · lab report OCR core (R1.3.134). One file shared by the app (window.WardOCR) and the test harness (require).
   On-device only: image processing in plain JS, text recognition by a Tesseract worker the caller provides.
   Never stores or sends the photo; returns values, confidences and in-memory crop boxes only. */
(function(root,factory){if(typeof module==="object"&&module.exports)module.exports=factory();else root.WardOCR=factory()})(typeof self!=="undefined"?self:this,function(){
"use strict";
const VERSION="ocr-core-1";
/* ---------- image helpers (grey Uint8Array, row-major) ---------- */
function toGrey(rgba,w,h){const g=new Uint8Array(w*h);for(let i=0,j=0;i<g.length;i++,j+=4)g[i]=(rgba[j]*77+rgba[j+1]*150+rgba[j+2]*29)>>8;return g}
function resize(g,w,h,nw,nh){ // area-average down, bilinear up
  const o=new Uint8Array(nw*nh);const sx=w/nw,sy=h/nh;
  if(sx>=1&&sy>=1){for(let y=0;y<nh;y++){const y0=Math.floor(y*sy),y1=Math.max(y0+1,Math.floor((y+1)*sy));for(let x=0;x<nw;x++){const x0=Math.floor(x*sx),x1=Math.max(x0+1,Math.floor((x+1)*sx));let s=0,n=0;for(let yy=y0;yy<y1&&yy<h;yy++){const r=yy*w;for(let xx=x0;xx<x1&&xx<w;xx++){s+=g[r+xx];n++}}o[y*nw+x]=n?s/n:255}}return o}
  for(let y=0;y<nh;y++){const fy=Math.min(h-1,(y+0.5)*sy-0.5);for(let x=0;x<nw;x++){o[y*nw+x]=bil(g,w,h,Math.min(w-1,(x+0.5)*sx-0.5),fy,255)}}return o;
}
function bil(g,w,h,x,y,bg){if(x<0||y<0||x>w-1||y>h-1)return bg;const x0=x|0,y0=y|0,x1=Math.min(x0+1,w-1),y1=Math.min(y0+1,h-1),fx=x-x0,fy=y-y0;
  const a=g[y0*w+x0],b=g[y0*w+x1],c=g[y1*w+x0],d=g[y1*w+x1];return (a*(1-fx)+b*fx)*(1-fy)+(c*(1-fx)+d*fx)*fy}
function boxBlur(g,w,h,r){const t=new Float32Array(w*h),o=new Uint8Array(w*h);const n=2*r+1;
  for(let y=0;y<h;y++){let s=0;const row=y*w;for(let x=-r;x<=r;x++)s+=g[row+Math.min(w-1,Math.max(0,x))];for(let x=0;x<w;x++){t[row+x]=s/n;s+=g[row+Math.min(w-1,x+r+1)]-g[row+Math.max(0,x-r)]}}
  for(let x=0;x<w;x++){let s=0;for(let y=-r;y<=r;y++)s+=t[Math.min(h-1,Math.max(0,y))*w+x];for(let y=0;y<h;y++){o[y*w+x]=s/n;s+=t[Math.min(h-1,y+r+1)*w+x]-t[Math.max(0,y-r)*w+x]}}return o}
function morph(g,w,h,r,isMax){const t=new Uint8Array(w*h),o=new Uint8Array(w*h);const f=isMax?Math.max:Math.min;
  for(let y=0;y<h;y++){const row=y*w;for(let x=0;x<w;x++){let v=g[row+x];for(let k=Math.max(0,x-r);k<=Math.min(w-1,x+r);k++)v=f(v,g[row+k]);t[row+x]=v}}
  for(let x=0;x<w;x++){for(let y=0;y<h;y++){let v=t[y*w+x];for(let k=Math.max(0,y-r);k<=Math.min(h-1,y+r);k++)v=f(v,t[k*w+x]);o[y*w+x]=v}}return o}
function otsu(g){const hist=new Float64Array(256);for(let i=0;i<g.length;i++)hist[g[i]]++;const tot=g.length;let sum=0;for(let i=0;i<256;i++)sum+=i*hist[i];
  let sB=0,wB=0,best=0,th=127;for(let i=0;i<256;i++){wB+=hist[i];if(!wB)continue;const wF=tot-wB;if(!wF)break;sB+=i*hist[i];const mB=sB/wB,mF=(sum-sB)/wF;const v=wB*wF*(mB-mF)*(mB-mF);if(v>best){best=v;th=i}}return th}
/* page outline: largest bright region, corners from extreme points (same rule as the prototype) */
function detectQuad(g,w,h){
  const sc=600/Math.max(w,h);const sw=Math.max(8,Math.round(w*sc)),sh=Math.max(8,Math.round(h*sc));
  let s=boxBlur(resize(g,w,h,sw,sh),sw,sh,2);const th=otsu(s);
  let b=new Uint8Array(sw*sh);for(let i=0;i<b.length;i++)b[i]=s[i]>th?255:0;
  b=morph(morph(b,sw,sh,5,true),sw,sh,5,false);
  const lab=new Int32Array(sw*sh).fill(-1);let best=null;const st=[];
  for(let i=0;i<b.length;i++){if(!b[i]||lab[i]>=0)continue;let n=0;const pts={s0:[1e9,0],s1:[-1e9,0],d0:[1e9,0],d1:[-1e9,0]};st.push(i);lab[i]=i;
    while(st.length){const p=st.pop();n++;const x=p%sw,y=(p/sw)|0;const S=x+y,D=y-x;if(S<pts.s0[0])pts.s0=[S,p];if(S>pts.s1[0])pts.s1=[S,p];if(D<pts.d0[0])pts.d0=[D,p];if(D>pts.d1[0])pts.d1=[D,p];
      if(x>0&&b[p-1]&&lab[p-1]<0){lab[p-1]=i;st.push(p-1)}if(x<sw-1&&b[p+1]&&lab[p+1]<0){lab[p+1]=i;st.push(p+1)}if(y>0&&b[p-sw]&&lab[p-sw]<0){lab[p-sw]=i;st.push(p-sw)}if(y<sh-1&&b[p+sw]&&lab[p+sw]<0){lab[p+sw]=i;st.push(p+sw)}}
    if(!best||n>best.n)best={n,pts}}
  const full=[[0,0],[w-1,0],[w-1,h-1],[0,h-1]];
  if(!best||best.n<0.30*sw*sh)return {quad:full,found:false};
  const P=p=>[(p%sw+0.5)/sc,(((p/sw)|0)+0.5)/sc];
  const q=[P(best.pts.s0[1]),P(best.pts.d0[1]),P(best.pts.s1[1]),P(best.pts.d1[1])];
  // reject degenerate outlines (a corner hidden by a fold): fall back to the full frame for the user to adjust
  const area=Math.abs(polyArea(q));if(area<0.25*w*h)return {quad:full,found:false};
  // a fold or a hand over a corner gives a skewed outline: only trust near-rectangles (each corner 90°±18°)
  for(let i=0;i<4;i++){const a=q[(i+3)%4],b=q[i],c=q[(i+1)%4];const v1=[a[0]-b[0],a[1]-b[1]],v2=[c[0]-b[0],c[1]-b[1]];
    const ang=Math.acos((v1[0]*v2[0]+v1[1]*v2[1])/(Math.hypot(...v1)*Math.hypot(...v2)+1e-9))*180/Math.PI;if(Math.abs(ang-90)>18)return {quad:full,found:false,outline:q}}
  return {quad:q,found:true};
}
function polyArea(q){let a=0;for(let i=0;i<4;i++){const [x1,y1]=q[i],[x2,y2]=q[(i+1)%4];a+=x1*y2-x2*y1}return a/2}
function solve(A,bv){const n=bv.length;for(let i=0;i<n;i++){let m=i;for(let r=i+1;r<n;r++)if(Math.abs(A[r][i])>Math.abs(A[m][i]))m=r;[A[i],A[m]]=[A[m],A[i]];[bv[i],bv[m]]=[bv[m],bv[i]];
  for(let r=i+1;r<n;r++){const f=A[r][i]/A[i][i];for(let c=i;c<n;c++)A[r][c]-=f*A[i][c];bv[r]-=f*bv[i]}}
  const x=new Array(n);for(let i=n-1;i>=0;i--){let s=bv[i];for(let c=i+1;c<n;c++)s-=A[i][c]*x[c];x[i]=s/A[i][i]}return x}
function homography(src,dst){const A=[],b=[];for(let i=0;i<4;i++){const [x,y]=src[i],[u,v]=dst[i];A.push([x,y,1,0,0,0,-u*x,-u*y]);b.push(u);A.push([0,0,0,x,y,1,-v*x,-v*y]);b.push(v)}const h=solve(A,b);return [...h,1]}
function warp(g,w,h,quad,longEdge){
  const d=(a,b)=>Math.hypot(a[0]-b[0],a[1]-b[1]);const [tl,tr,br,bl]=quad;
  let W=Math.max(d(br,bl),d(tr,tl)),H=Math.max(d(tr,br),d(tl,bl));const sc=(longEdge||2000)/Math.max(W,H);W=Math.round(W*sc);H=Math.round(H*sc);
  const M=homography([[0,0],[W-1,0],[W-1,H-1],[0,H-1]],quad);const o=new Uint8Array(W*H);
  for(let y=0;y<H;y++)for(let x=0;x<W;x++){const z=M[6]*x+M[7]*y+1;o[y*W+x]=bil(g,w,h,(M[0]*x+M[1]*y+M[2])/z,(M[3]*x+M[4]*y+M[5])/z,255)}
  return {g:o,w:W,h:H};
}
function flatten(g,w,h){ // remove shadows / uneven light: background = local max, smoothed
  const r=Math.max(2,Math.round(w/600));const bg=boxBlur(morph(g,w,h,r*2,true),w,h,r*8);const f=new Uint8Array(w*h);
  for(let i=0;i<f.length;i++){const v=255-(bg[i]-g[i]);f[i]=v<0?0:v>255?255:v}
  const hist=new Uint32Array(256);for(let i=0;i<f.length;i++)hist[f[i]]++;let lo=0,hi=255,c=0;const n=f.length;
  for(let i=0;i<256;i++){c+=hist[i];if(c>n*0.005){lo=i;break}}c=0;for(let i=255;i>=0;i--){c+=hist[i];if(c>n*0.25){hi=i;break}}
  const span=Math.max(30,hi-lo);for(let i=0;i<f.length;i++){const v=(f[i]-lo)*255/span;f[i]=v<0?0:v>255?255:v}return f}
function skewAngle(g,w,h){
  const sc=1000/w;const sw=1000,sh=Math.round(h*sc);const s=resize(g,w,h,sw,sh);const th=Math.min(otsu(s),170);const pts=[];
  for(let y=0;y<sh;y++)for(let x=0;x<sw;x++)if(s[y*sw+x]<th)pts.push(x-sw/2,y-sh/2);
  let best=[0,-1];for(let a=-5;a<=5.001;a+=0.25){const r=a*Math.PI/180,cs=Math.cos(r),sn=Math.sin(r);const hist=new Float64Array(sh*2+4);
    for(let i=0;i<pts.length;i+=2){const yy=Math.round(-pts[i]*sn+pts[i+1]*cs+sh);if(yy>=0&&yy<hist.length)hist[yy]++}
    let m=0;for(const v of hist)m+=v;m/=hist.length;let vr=0;for(const v of hist)vr+=(v-m)*(v-m);if(vr>best[1])best=[a,vr]}
  return best[0];
}
function rotate(g,w,h,deg){if(!deg)return g;const r=-deg*Math.PI/180,cs=Math.cos(r),sn=Math.sin(r),cx=w/2,cy=h/2;const o=new Uint8Array(w*h);
  for(let y=0;y<h;y++)for(let x=0;x<w;x++){const dx=x-cx,dy=y-cy;o[y*w+x]=bil(g,w,h,cs*dx-sn*dy+cx,sn*dx+cs*dy+cy,255)}return o}
function sharpness(g,w,h){ // variance of the Laplacian on a 1000-px-wide copy
  const sc=1000/Math.max(w,h);const sw=Math.round(w*sc),sh=Math.round(h*sc);const s=resize(g,w,h,sw,sh);let m=0,m2=0,n=0;
  for(let y=1;y<sh-1;y++)for(let x=1;x<sw-1;x++){const i=y*sw+x;const l=4*s[i]-s[i-1]-s[i+1]-s[i-sw]-s[i+sw];m+=l;m2+=l*l;n++}m/=n;return m2/n-m*m}
/* full preparation. quad (4 points, tl tr br bl) in source pixels; omitted = auto-detect */
function prepare(rgba,w,h,opt){opt=opt||{};const t0=Date.now();
  const g=toGrey(rgba,w,h);const q=opt.quad==='full'?{quad:[[0,0],[w-1,0],[w-1,h-1],[0,h-1]],found:false}:opt.quad?{quad:opt.quad,found:true,user:true}:detectQuad(g,w,h);
  const wp=warp(g,w,h,q.quad,opt.longEdge||2000);const f=flatten(wp.g,wp.w,wp.h);const ang=opt.noDeskew?0:skewAngle(f,wp.w,wp.h);const out=rotate(f,wp.w,wp.h,ang);
  const sharp=sharpness(g,w,h);const longSrc=Math.max(w,h);
  const quality={longEdge:longSrc,sharpness:Math.round(sharp),lowRes:longSrc<1400,blurry:sharp<QUALITY.blurMin,pageFound:q.found,skew:ang};
  return {grey:out,w:wp.w,h:wp.h,quad:q.quad,quality,ms:Date.now()-t0};
}
const QUALITY={blurMin:60};
function crop(g,w,h,x,y,cw,ch,scale){scale=scale||1;const W=Math.max(1,Math.round(cw*scale)),H=Math.max(1,Math.round(ch*scale));const o=new Uint8Array(W*H);
  for(let yy=0;yy<H;yy++)for(let xx=0;xx<W;xx++)o[yy*W+xx]=bil(g,w,h,x+xx/scale,y+yy/scale,255);return {g:o,w:W,h:H}}
function greyToRgba(g){const o=new Uint8ClampedArray(g.length*4);for(let i=0,j=0;i<g.length;i++,j+=4){o[j]=o[j+1]=o[j+2]=g[i];o[j+3]=255}return o}

/* ---------- report dictionary (AMCH templates) → app test codes ---------- */
// syn: printed names (lower case). unit/ref: as AMCH prints them (used only to cross-check the read).
const TESTS={
 cbc:{hb:{syn:["haemoglobin","hemoglobin"],unit:"g/dL",ref:"13-17"},wbc:{syn:["total wbc count","wbc count","total wbc"],unit:"10^3/uL",ref:"4-10"},
  neut:{syn:["neutrophil","neutrophils"],unit:"%",ref:"40-80"},lymph:{syn:["lymphocyte","lymphocytes"],unit:"%",ref:"20-40"},mono:{syn:["monocyte","monocytes"],unit:"%",ref:"2-10"},
  eos:{syn:["eosinophil","eosinophils"],unit:"%",ref:"1-6"},baso:{syn:["basophil","basophils"],unit:"%",ref:"0-2"},rbc:{syn:["rbc count"],unit:"10^6/uL",ref:"4.50-5.50"},
  hct:{syn:["hct","pcv"],unit:"%",ref:"40-50"},mcv:{syn:["mcv"],unit:"fL",ref:"83-101"},mch:{syn:["mch"],unit:"pg",ref:"27-32"},mchc:{syn:["mchc"],unit:"g/dL",ref:"31.5-34.5"},
  rdw:{syn:["rdw cv","rdw-cv","rdw"],unit:"%",ref:"11.6-14.0"},plt:{syn:["platelet count","platelet"],unit:"10^3/uL",ref:"150-410"}},
 bio:{tp:{syn:["total protein"],unit:"g/dL",ref:"6.30-8.20"},alb:{syn:["albumin"],unit:"g/dL",ref:"3.50-5.00"},glob:{syn:["globulin"],unit:"g/dL",ref:"2.80-3.20"},
  ag:{syn:["albumin globulin ratio","a/g ratio"],unit:"",ref:"1.30-1.50"},tbil:{syn:["total bilirubin"],unit:"mg/dL",ref:"0.20-1.30"},
  ubil:{syn:["bilirubin unconjugated","unconjugated bilirubin","indirect bilirubin"],unit:"mg/dL",ref:"0.0-1.1"},dbil:{syn:["direct bilirubin","bilirubin direct","conjugated bilirubin"],unit:"mg/dL",ref:"0.00-0.30"},
  alt:{syn:["sgpt ( alt)","sgpt (alt)","sgpt"],unit:"U/L",ref:"<50"},ast:{syn:["sgot (ast)","sgot"],unit:"U/L",ref:"17-59"},alp:{syn:["alkaline phosphatase"],unit:"U/L",ref:"38-126"},
  ggt:{syn:["gamma glutamyl transferase","gamma gt","ggt"],unit:"U/L",ref:"15-73"},urea:{syn:["urea"],unit:"mg/dL",ref:"19.26-42.8"},creat:{syn:["creatinine"],unit:"mg/dL",ref:"0.66-1.25"},
  na:{syn:["sodium"],unit:"mmol/L",ref:"137-145"},k:{syn:["potassium"],unit:"mmol/L",ref:"3.50-5.10"},rbs:{syn:["random blood sugar","glucose random","blood sugar random"],unit:"mg/dL",ref:"70-140"},
  chol:{syn:["cholesterol","total cholesterol"],unit:"mg/dL",ref:""},tg:{syn:["triglycerides","triglyceride"],unit:"mg/dL",ref:""},hdl:{syn:["hdl","hdl cholesterol"],unit:"mg/dL",ref:"40-60"},
  vldl:{syn:["vldl","vldl cholesterol"],unit:"mg/dL",ref:"<50.00"},ldl:{syn:["ldl","ldl cholesterol"],unit:"mg/dL",ref:"0.00-130"},hba1c:{syn:["hba1c (glycosylated hb)","hba1c","glycosylated hb"],unit:"%",ref:""},
  tsh:{syn:["tsh","thyroid stimulating hormone"],unit:"uIU/mL",ref:"0.40-4.05"},amylase:{syn:["amylase"],unit:"U/L",ref:"30-110"},lipase:{syn:["lipase"],unit:"U/L",ref:"23-300"},
  li:{syn:["lithium","serum lithium"],unit:"mmol/L",ref:""},vpa:{syn:["valproate","valproic acid","serum valproate"],unit:"ug/mL",ref:""}},
 urine:{u_volume:{syn:["volume"],unit:"mL"},u_colour:{syn:["colour","color"],txt:1},u_appearance:{syn:["appearance/transparency","appearance"],txt:1},u_ph:{syn:["reaction(ph)","reaction (ph)","reaction"]},
  u_sg:{syn:["specific gravity"],ref:"1.003-1.030"},u_glucose:{syn:["glucose"],txt:1},u_protein:{syn:["protein"],txt:1},u_ketone:{syn:["ketone bodies","ketone"],txt:1},u_blood:{syn:["blood"],txt:1},
  u_urobilinogen:{syn:["urobilinogen"],txt:1},u_bilirubin:{syn:["bilirubin"],txt:1},u_nitrite:{syn:["nitrite"],txt:1},u_epithelial:{syn:["epithelial cells","epithelial cell"],txt:1},
  u_pus:{syn:["leucocyte/pus cell/ wbc","leucocyte/pus cell","pus cells","pus cell"],txt:1},u_rbc:{syn:["r.b.c","rbc"],txt:1},u_crystals:{syn:["crystals"],txt:1},u_casts:{syn:["casts"],txt:1},u_bacteria:{syn:["bacteria"],txt:1}}
};
const UNITS={"g/dl":"g/dL","gm/dl":"g/dL","gm/dI":"g/dL","%":"%","fl":"fL","pg":"pg","mg/dl":"mg/dL","mmol/l":"mmol/L","u/l":"U/L","iu/l":"U/L","10^3/ul":"10^3/uL","10^6/ul":"10^6/uL",
  "uiu/ml":"uIU/mL","µiu/ml":"uIU/mL","piu/ml":"uIU/mL","ml":"mL","/hpf":"/HPF","/lpf":"/LPF","ug/ml":"ug/mL","µg/ml":"ug/mL"};
const QUAL=/^(negative|positive|normal|absent|present|nil|trace|straw|clear|turbid|pale|yellow|occasional|plenty|\d+-\d+|\+{1,4})$/i;
function normName(s){return String(s||"").toLowerCase().replace(/[|]/g,"l").replace(/\s+/g," ").trim()}
function lev(a,b){if(a===b)return 0;const m=a.length,n=b.length;if(!m)return n;if(!n)return m;let p=new Array(n+1),c=new Array(n+1);for(let j=0;j<=n;j++)p[j]=j;
  for(let i=1;i<=m;i++){c[0]=i;for(let j=1;j<=n;j++)c[j]=Math.min(p[j]+1,c[j-1]+1,p[j-1]+(a[i-1]===b[j-1]?0:1));[p,c]=[c,p]}return p[n]}
function sim(a,b){const L=Math.max(a.length,b.length);return L?1-lev(a,b)/L:1}
function detectTemplate(text){const t=text.toLowerCase();
  if(/clinical patholog|urine|specific gravity|pus cell/.test(t))return "urine";
  if(/haematolog|hematolog|complete blood|d\.?l\.?c|platelet count|haemoglobin/.test(t))return "cbc";
  if(/biochem|bilirubin|creatinine|urea|sgpt|sodium|cholesterol|tsh|protein/.test(t))return "bio";
  return "bio";}
/* ---------- tesseract TSV → lines ---------- */
function tsvLines(tsv){const lines=new Map();String(tsv||"").split("\n").forEach(r=>{const c=r.split("\t");if(c.length<12||c[0]!=="5")return;const txt=c.slice(11).join("\t").trim();if(!txt)return;
    const k=c[2]+"/"+c[3]+"/"+c[4];const w={t:txt,x:+c[6],y:+c[7],w:+c[8],h:+c[9],conf:+c[10]};if(!lines.has(k))lines.set(k,[]);lines.get(k).push(w)});
  return [...lines.values()].map(ws=>{ws.sort((a,b)=>a.x-b.x);const y0=Math.min(...ws.map(w=>w.y)),y1=Math.max(...ws.map(w=>w.y+w.h));return {words:ws,text:ws.map(w=>w.t).join(" "),y0,y1,x0:ws[0].x}}).sort((a,b)=>a.y0-b.y0||a.x0-b.x0)}
const NUMRE=/^[<>]?\d+(?:[.,]\d+)?$/;
function cleanNum(t){let s=String(t).replace(/[Oo]/g,"0").replace(/[lI|]/g,"1").replace(/,/g,".").replace(/[^\d.<>]/g,"");s=s.replace(/^\.+|\.+$/g,"");if((s.match(/\./g)||[]).length>1)return null;return /^[<>]?\d+(\.\d+)?$/.test(s)?s:null}
function unitKey(u){return String(u||"").toLowerCase().replace(/\s/g,"").replace(/µ/g,"u").replace(/["'*°]/g,"^").replace(/^10\^?7/,"10^").replace(/^10(?=[36]\/)/,"10^")}
function normUnit(u){const k=unitKey(u);return UNITS[k]||UNITS[k.replace(/^10\^?([36])\/?$/,"10^$1/ul")]||String(u||"").trim()}
function refKey(r){return String(r||"").replace(/\s/g,"").replace(/[–—]/g,"-").toLowerCase()}
/* match the start of a line against the template's test names */
function matchName(line,dict){
  const words=line.words;let best=null;
  for(let n=1;n<=Math.min(5,words.length);n++){const head=normName(words.slice(0,n).map(w=>w.t).join(" ")).replace(/^[^a-z(]+/,"");if(!head)continue;
    for(const code in dict){for(const s of dict[code].syn){const sc=head===s?1:(s.length>=5?sim(head,s):0);if(sc>=0.84&&(!best||sc>best.sc||(sc===best.sc&&s.length>best.len)))best={code,n,sc,len:s.length,syn:s}}}}
  if(best)return best;
  // photo cut the left edge: the line starts part-way into the name ("ithelial cells", "rystals")
  for(let n=1;n<=Math.min(4,words.length);n++){const head=normName(words.slice(0,n).map(w=>w.t).join(" ")).replace(/^[^a-z]+/,"");if(head.replace(/[^a-z]/g,"").length<4)continue;
    const hits=[];for(const code in dict)for(const s of dict[code].syn){if(s.length<=head.length)continue;const tail=s.slice(s.length-head.length);const sc=tail===head?0.85:(head.length>=6&&sim(tail,head)>=0.8?0.8:0);if(sc)hits.push({code,n,sc,len:s.length,syn:s,partial:1})}
    const codes=[...new Set(hits.map(h=>h.code))];if(codes.length===1){hits.sort((a,b)=>b.sc-a.sc);if(!best||hits[0].sc>=best.sc)best=hits[0]}}
  return best;
}
/* parse recognised lines into results. Each row: {code,value,unit,ref,conf,box,via,reasons[]} */
function parseLines(lines,tpl){
  const dict=TESTS[tpl]||TESTS.bio;const out={};let resCol=null,unitCol=null;
  for(const L of lines){const t=L.text.toLowerCase();
    if(!resCol&&/\bresults?\b/.test(t)&&/\bunit/.test(t)){const r=L.words.find(w=>/^results?$/i.test(w.t));const u=L.words.find(w=>/^units?$/i.test(w.t));if(r)resCol={x0:r.x-r.w*0.6,x1:(u?u.x:r.x+r.w*2)};if(u)unitCol={x0:u.x-u.w*0.5,x1:u.x+u.w*2.5}}}
  lines.forEach((L,li)=>{
    const m=matchName(L,dict);if(!m||out[m.code])return;
    if(m.code==="mch"&&/^mchc/i.test(L.words[0].t))return;
    const rest=L.words.slice(m.n);const def=dict[m.code];
    let vw=null,vi=-1;
    for(let i=0;i<rest.length;i++){const w=rest[i];const s=w.t.replace(/^[:=\-]+/,"");if(!s)continue;
      if(def.txt){if(QUAL.test(s)||/^\d/.test(s)){vw=w;vi=i;break}if(/^[a-z]/i.test(s)&&i===0&&s.length>2){vw=w;vi=i;break}continue}
      if(cleanNum(s)!=null){vw=Object.assign({},w,{t:s});vi=i;break}
      if(resCol&&w.x>resCol.x1)break;}
    let via="line";
    if(!vw&&resCol){ // value printed on its own (e.g. the line wrapped): look in the RESULTS column at this height
      const cy=(L.y0+L.y1)/2,lh=Math.max(10,L.y1-L.y0);
      for(const L2 of lines){if(Math.abs((L2.y0+L2.y1)/2-cy)>lh*0.7)continue;for(const w of L2.words){if(w.x>=resCol.x0&&w.x<=resCol.x1&&cleanNum(w.t)!=null){vw=Object.assign({},w,{t:cleanNum(w.t)});via="column";break}}if(vw)break}}
    if(!vw){out[m.code]={code:m.code,value:null,conf:0,box:null,via:"none",name:m.syn,nameScore:m.sc,lineBox:{x:L.x0,y:L.y0,h:L.y1-L.y0},reasons:["Value not read"]};return}
    let value=def.txt?vw.t:cleanNum(vw.t);let after=vi>=0?rest.slice(vi+1):[];
    if(def.txt){const more=[];for(const w of after){if(QUAL.test(w.t)&&/^(yellow)$/i.test(w.t)){more.push(w.t)}else break}if(more.length)value+=" "+more.join(" ");}
    let unit="",ref="";
    if(after.length){
      let u=after[0].t;if(/\/$/.test(u)&&lines[li+1]){const nx=lines[li+1].words[0];if(nx&&/^(u|µ|p)?[lL]$/.test(nx.t))u+="uL"}
      const nu=normUnit(u);if(Object.values(UNITS).includes(nu)||/^10\^/.test(nu))unit=nu;
      const tail=after.map(w=>w.t).join(" ");const rm=tail.match(/(\d+(?:\.\d+)?)\s*-\s*(\d+(?:\.\d+)?)\s*$/)||tail.match(/([<>]=?\s*\d+(?:\.\d+)?)\s*$/);
      if(rm)ref=rm[2]!==undefined?rm[1]+"-"+rm[2]:rm[1].replace(/\s/g,"");}
    out[m.code]={code:m.code,value,unit,ref,conf:vw.conf,box:{x:vw.x,y:vw.y,w:vw.w,h:vw.h},via,name:m.syn,nameScore:m.sc,lineBox:{x:L.x0,y:L.y0,h:L.y1-L.y0},reasons:[]};
  });
  // test name unreadable: identify the test from its printed normal range when that range is unique on this template
  const byRef={};for(const code in dict){const r=dict[code].ref;if(!r)continue;const k=String(r).replace(/[^\d]/g,"");if(k.length<3)continue;(byRef[k]=byRef[k]||[]).push(code)}
  lines.forEach(L=>{if(matchName(L,dict))return;const tail=L.text.match(/(\d+(?:[.,]\d+)?)\s*-\s*(\d+(?:[.,]\d+)?)\s*$/);if(!tail)return;
    const k=(tail[1]+tail[2]).replace(/[^\d]/g,"");const codes=byRef[k];if(!codes||codes.length!==1||out[codes[0]])return;const code=codes[0];
    const vw=L.words.find(w=>cleanNum(w.t)!=null&&(!resCol||(w.x>=resCol.x0&&w.x<=resCol.x1)));if(!vw||L.words.indexOf(vw)>=L.words.length-1&&!resCol)return;
    const vi=L.words.indexOf(vw);const u=L.words[vi+1]?normUnit(L.words[vi+1].t):"";
    out[code]={code,value:cleanNum(vw.t),unit:Object.values(UNITS).includes(u)?u:(L.words[vi+1]?L.words[vi+1].t:""),ref:tail[1]+"-"+tail[2],conf:vw.conf,box:{x:vw.x,y:vw.y,w:vw.w,h:vw.h},via:"range",name:"",nameScore:0,lineBox:{x:L.x0,y:L.y0,h:L.y1-L.y0},reasons:["Test name not read: matched by its normal range"]}});
  return out;
}
/* ---------- header: name, dates, sample no, page ---------- */
const MON={jan:1,feb:2,mar:3,apr:4,may:5,jun:6,jul:7,aug:8,sep:9,oct:10,nov:11,dec:12};
function dateOf(s){const m=String(s).match(/(\d{1,2})[-/.](\d{1,2})[-/.](20\d{2})/);if(!m)return "";const d=+m[1],mo=+m[2];if(d<1||d>31||mo<1||mo>12)return "";return m[3]+"-"+String(mo).padStart(2,"0")+"-"+String(d).padStart(2,"0")}
function header(lines,pageW){
  const h={name:"",nameConf:0,sample:"",collected:"",reported:"",page:null,pages:null};
  for(const L of lines){const t=L.text;
    if(!h.name){const i=L.words.findIndex((w,j)=>j<3&&/^(n[ae][mr]n?[e€c]|nam|narne|name|yme|ame|me)$/i.test(w.t.replace(/[^a-z€]/gi,"")));
      if(i>=0){const nm=upperRun(L.words.slice(i+1),L.words[i].x,pageW,true);if(nm){h.name=nm.text;h.nameConf=nm.conf}}}
    if(!h.sample){const m=t.match(/Sample\s*No\.?\s*[:;.]?\s*([A-Z_]+\/[A-Z0-9]+)/i)||t.match(/\b((?:P_)?(?:IPD|EC|OPD)(?:_BIO)?\/[A-Z]?\d+)\b/);if(m)h.sample=m[1].toUpperCase()}
    if(!h.collected&&/oll?ection|ection T/i.test(t)){h.collected=dateOf(t)}
    if(!h.reported&&/report(ing)?\s*T|complet|ing Time/i.test(t)){h.reported=dateOf(t)}
    const pm=t.match(/Page\s*(\d)\s*of\s*(\d)/i);if(pm){h.page=+pm[1];h.pages=+pm[2]}}
  if(!h.name){ // label unreadable: the name is the line just above "Age - Sex" (… Years - Male/Female)
    const ai=lines.findIndex(L=>/years?\s*[-–]?\s*(male|female|m\b|f\b)/i.test(L.text));
    if(ai>0){const L=lines[ai-1];const nm=upperRun(L.words,0,pageW);if(nm&&!/sample/i.test(L.text)){h.name=nm.text;h.nameConf=nm.conf;h.nameVia="position"}}}
  if(!h.collected){for(const L of lines){const d=dateOf(L.text);if(d){h.collected=d;break}}}
  return h;
}
// AMCH prints names in capitals: take the longest run of capitalised words left of the right-hand column
function upperRun(ws,x0,pageW,labelled){const lim=Math.max((x0||0)+pageW*0.38,pageW*0.5);let best=[],cur=[];
  for(const w of ws){if(w.x>lim)break;const t=w.t.replace(/^[:;.,+'"]+|[:;.,'"]+$/g,"");if(!t)continue;
    if(/^(hospital|ward|hosp|collection)/i.test(t))break;
    const letters=t.replace(/[^A-Za-z]/g,""),ups=t.replace(/[^A-Z]/g,"");
    const nameLike=/^[A-Za-z!|'.-]+$/.test(t)&&letters.length>=1&&(labelled?(ups.length>=letters.length*0.5||cur.length>0):ups.length===letters.length);
    if(nameLike&&!/^(NAME|SAMPLE|NO|AGE|SEX|WARD|HOSPITAL)$/i.test(t)){cur.push({t:t.toUpperCase().replace(/[!|]/g,"I"),conf:w.conf})}else if(cur.length){if(cur.length>best.length)best=cur;cur=[]}}
  if(cur.length>best.length)best=cur;const text=best.map(x=>x.t).join(" ");if(text.replace(/[^A-Z]/g,"").length<2)return null;
  return {text,conf:Math.round(best.reduce((a,x)=>a+x.conf,0)/best.length)}}
/* ---------- patient-name match (printed name vs the card the scan was started from) ---------- */
const TITLES=new Set(["mr","mrs","ms","miss","mst","md","mohd","mohammad","mohammed","muhammad","dr","smt","sri","shri","shree","baby","master","kumari","late"]);
const ABBR={kr:"kumar",kum:"kumar",md:"mohammad",mohd:"mohammad",ch:"chandra",chd:"chandra",pd:"prasad",prd:"prasad",nath:"nath"};
function nameTokens(s){
  const t=String(s||"").normalize("NFKD").replace(/[\u0300-\u036f]/g,"").toLowerCase()
    .replace(/0/g,"o").replace(/1|\||!/g,"i").replace(/5/g,"s").replace(/8/g,"b").replace(/[^a-z .'-]/g," ").replace(/[.'-]/g," ").replace(/\s+/g," ").trim();
  return t?t.split(" ").filter(Boolean).map(w=>ABBR[w]&&!TITLES.has(w)?ABBR[w]:w).filter(w=>!TITLES.has(w)):[];
}
function tokOk(a,b){if(a===b)return 2;const L=Math.max(a.length,b.length);if(a.length===1||b.length===1)return a[0]===b[0]?1:0; // initials
  const d=lev(a,b);if(L>=8?d<=2:L>=4?d<=1:false)return 2;
  if(a.length>=3&&b.length>=3&&(a.startsWith(b)||b.startsWith(a)))return 1;return 0}
function nameMatch(printed,card){
  const P=nameTokens(printed),C=nameTokens(card);
  const letters=P.join("").length;
  if(!C.length)return {status:"unread",score:0,why:"No name on the card"};
  if(letters<3)return {status:"unread",score:0,why:"Name not readable on the report"};
  // spacing errors: compare glued strings in both orders
  const gP=P.join(""),gC=C.join(""),gCr=C.slice().reverse().join("");
  const glue=Math.max(sim(gP,gC),sim(gP,gCr));
  // token alignment: every token of the shorter name must find a partner; at least one full-word (non-initial) partner
  const [S,Lg]=P.length<=C.length?[P,C]:[C,P];const used=new Set();let full=0,part=0,miss=0;
  for(const a of S){let bi=-1,bs=0;Lg.forEach((b,i)=>{if(used.has(i))return;const s=tokOk(a,b);if(s>bs){bs=s;bi=i}});if(bi<0){miss++;continue}used.add(bi);if(bs===2&&a.length>1)full++;else part++}
  // the longer name may carry an extra middle name / initial only
  const extra=Lg.filter((_,i)=>!used.has(i)).filter(t=>t.length>1).length;
  let ok=miss===0&&full>=1&&(S.length>=2||Lg.length===1)&&extra<=1;
  // surname (last word on the card) must agree when both have one
  if(ok&&C.length>=2&&P.length>=2){const ls=C[C.length-1];if(!P.some(t=>tokOk(t,ls)===2))ok=false}
  if(!ok&&glue>=0.9&&Math.abs(gP.length-gC.length)<=2)ok=true;
  const score=Math.round(100*(ok?Math.max(glue,(full+part*0.6)/Math.max(1,Lg.length)):Math.min(glue,0.79)))/100;
  return ok?{status:"match",score,why:""}:{status:"mismatch",score,why:"Name on the report does not match this patient"};
}
/* ---------- checks that set amber / red per value ---------- */
function plausible(code){return ({hb:[2,25],wbc:[0.1,500],neut:[0,100],lymph:[0,100],mono:[0,100],eos:[0,100],baso:[0,100],rbc:[0.5,10],hct:[5,75],mcv:[40,150],mch:[10,50],mchc:[20,45],rdw:[8,35],plt:[1,2000],
  tbil:[0,50],dbil:[0,40],ubil:[0,50],tp:[2,14],alb:[0.5,7],glob:[0.5,10],ag:[0.1,5],ast:[1,10000],alt:[1,10000],alp:[5,5000],ggt:[1,5000],urea:[2,500],creat:[0.1,20],na:[90,200],k:[1,10],rbs:[10,1500],
  chol:[30,1000],tg:[10,5000],hdl:[5,200],ldl:[5,600],vldl:[1,1000],hba1c:[3,20],tsh:[0.005,150],amylase:[1,5000],lipase:[1,10000],li:[0.05,5],vpa:[1,400],u_volume:[1,5000],u_ph:[4,9.5],u_sg:[1,1.06]})[code]||null}
function decimalsExpected(tpl,code){const d=(TESTS[tpl]||{})[code];const r=d&&d.ref||"";return /\.\d/.test(r)}
const CONF_GREEN=88;
// decimals AMCH prints for each test (fixed format); used only to suggest where a dropped point belongs
const DP={cbc:{hb:2,wbc:2,neut:2,lymph:2,mono:2,eos:2,baso:2,rbc:2,hct:2,mcv:2,mch:2,mchc:2,rdw:2,plt:2},
  bio:{tp:2,alb:2,glob:2,ag:1,tbil:2,ubil:2,dbil:2,alt:2,ast:2,alp:2,ggt:2,urea:2,creat:2,na:2,k:2,chol:2,tg:2,hdl:2,vldl:2,hba1c:1,tsh:2,amylase:2,lipase:2}};
function repairDecimal(row,tpl){const dp=(DP[tpl]||{})[row.code];const raw=String(row.value);if(!dp||!/^\d+$/.test(raw)||raw.length<=dp)return;
  const p=plausible(row.code);const v=+raw;const fixed=raw.slice(0,raw.length-dp)+"."+raw.slice(-dp);const fv=+fixed;
  const ref=((TESTS[tpl]||{})[row.code]||{}).ref||"";const top=Math.max(0,...(ref.match(/\d+(\.\d+)?/g)||[]).map(Number));
  const implausible=p&&(v<p[0]||v>p[1]);const far=top&&v>5*top&&fv<=5*top;
  if((implausible||far)&&(!p||(fv>=p[0]&&fv<=p[1]))){row.firstRead=raw;row.value=fixed;row.reasons.push("Decimal point added (read "+raw+")")}}
function grade(row,tpl,reread){
  const R=row.reasons;const def=(TESTS[tpl]||{})[row.code]||{};
  if(row.value==null){row.state="red";return row}
  if(!def.txt)repairDecimal(row,tpl);
  if(!def.txt){const v=parseFloat(String(row.value).replace(/^[<>]/,""));const p=plausible(row.code);
    if(p&&(v<p[0]||v>p[1])){R.push("Outside the possible range");row.state="red";return row}
    if(decimalsExpected(tpl,row.code)&&!/\./.test(row.value)){const top=Math.max(...(String(def.ref).match(/\d+(\.\d+)?/g)||["0"]).map(Number));if(top&&v>3*top){R.push("Decimal point missing?");row.state="red";return row}R.push("No decimal point read")}
    if(reread&&reread.value!=null){const a=String(row.value).replace(/^[<>]/,""),b=String(reread.value).replace(/^[<>]/,"");const da=a.replace(/\D/g,""),db=b.replace(/\D/g,"");
      if(+a===+b||da===db)row.agree=true;else if(Math.abs(da.length-db.length)<=1&&lev(da,db)<=1)R.push("Two reads differ ("+a+" / "+b+")");else row.agree=false}}
  if(row.conf<CONF_GREEN&&!(row.agree&&row.conf>=70))R.push("Low confidence ("+Math.round(row.conf)+"%)");
  if(row.via==="column")R.push("Read from the results column");
  if(def.unit&&row.unit&&row.unit!==def.unit)R.push("Unit reads "+row.unit);
  if(def.ref&&row.ref&&refKey(row.ref)!==refKey(def.ref)&&String(row.ref).replace(/[^\d]/g,"")!==String(def.ref).replace(/[^\d]/g,"")){row.info=(row.info||[]).concat("Range reads "+row.ref);if(!(row.agree&&row.conf>=CONF_GREEN))R.push("Range reads "+row.ref)}
  // a partly read test name is fine when its printed normal range is exactly this test's and two reads agree
  if(row.nameScore<1){const refOk=def.ref&&row.ref&&(refKey(row.ref)===refKey(def.ref)||String(row.ref).replace(/[^\d]/g,"")===String(def.ref).replace(/[^\d]/g,""));
    const vocabOk=def.txt&&QUAL.test(String(row.value))&&row.nameScore>=0.88&&row.via!=="range";
    if((refOk&&(row.agree||def.txt)&&row.conf>=70)||(vocabOk&&row.conf>=80))row.info=(row.info||[]).concat("Test name partly read; range matches");else R.push("Test name partly read")}
  row.state=R.length?"amber":"green";return row;
}
/* ---------- orchestration (engine-agnostic) ----------
   engine.page(img) → {tsv}; engine.digits(crop) → {text, conf}. img/crop are {g,w,h} grey bitmaps. */
async function read(prep,engine,opt){opt=opt||{};const t0=Date.now();
  const pg={g:prep.grey,w:prep.w,h:prep.h};const r=await engine.page(pg);const lines=tsvLines(r.tsv);const text=lines.map(l=>l.text).join("\n");
  const tpl=opt.tpl||detectTemplate(text);const rows=parseLines(lines,tpl);const hdr=header(lines,prep.w);
  const codes=Object.keys(rows);let ix=0;
  for(const code of codes){const row=rows[code];if(opt.progress)try{opt.progress(++ix,codes.length)}catch(e){}const def=(TESTS[tpl]||{})[code]||{};let rr=null;
    if(!def.txt&&row.box&&engine.digits&&opt.reread!==false){const b=row.box;const pad=Math.round(b.h*0.8);const sc=Math.min(3,Math.max(1,40/Math.max(8,b.h)));
      const c=crop(pg.g,pg.w,pg.h,b.x-pad,b.y-pad,b.w+pad*2,b.h+pad*2,sc);try{const d=await engine.digits(c);const v=cleanNum(String(d.text||"").trim());rr={value:v,conf:d.conf}}catch(e){rr={value:null,conf:0}}
      // a confident second read that passes the checks replaces an unsure first read
      if(rr.value!=null&&String(+rr.value)!==String(+String(row.value).replace(/^[<>]/,""))&&rr.conf>row.conf+10){const p=plausible(code);const v=parseFloat(rr.value);if(!p||(v>=p[0]&&v<=p[1])){row.firstRead=row.value;row.value=rr.value}}}
    grade(row,tpl,rr);row.reread=rr;}
  const vals=Object.values(rows).filter(x=>x.value!=null);const mean=vals.length?vals.reduce((a,x)=>a+x.conf,0)/vals.length:0;
  return {tpl,rows,header:hdr,text,meanConf:Math.round(mean*10)/10,ms:Date.now()-t0,lines:lines.length};
}
return {VERSION,TESTS,QUALITY,toGrey,resize,detectQuad,warp,flatten,skewAngle,rotate,sharpness,prepare,crop,greyToRgba,tsvLines,parseLines,header,nameTokens,nameMatch,grade,read,detectTemplate,cleanNum,normUnit,dateOf,lev,sim};
});
