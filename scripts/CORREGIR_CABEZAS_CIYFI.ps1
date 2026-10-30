param(
 [string]$Proyecto = 'C:\Users\cancu\Pictures\PROYECTO TORTUGAS\zproyecto3_0',
 [string]$Salida = 'C:\Users\cancu\Pictures\PROYECTO TORTUGAS\zproyecto3_0\recortes3_0\ciyfi_20261004_001459_146400',
 [string]$Dataset = ''
)
$ErrorActionPreference = 'Stop'
$python = Join-Path $Proyecto '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { throw "No se encontro Python: $python" }
$env:PYTHONIOENCODING = 'utf-8'
$env:PYTHONUTF8 = '1'
@'
import csv, hashlib, json, math, sys, zipfile
from pathlib import Path
from datetime import datetime
import tkinter as tk
from tkinter import ttk, messagebox
from PIL import Image, ImageOps, ImageTk, ImageDraw


def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def read_image(p):
    with Image.open(p) as f:
        f.seek(0)
        out=ImageOps.exif_transpose(f).convert('RGB'); out.load(); return out

def atomic_json(p,d):
    tmp=p.with_suffix('.tmp'); tmp.write_text(json.dumps(d,ensure_ascii=False,indent=2),encoding='utf-8'); tmp.replace(p)

def box_pixels(a,b,size):
    w,h=size
    x1=max(0,min(w,math.floor(min(a[0],b[0])))); x2=max(0,min(w,math.ceil(max(a[0],b[0]))))
    y1=max(0,min(h,math.floor(min(a[1],b[1])))); y2=max(0,min(h,math.ceil(max(a[1],b[1]))))
    if x2-x1<8 or y2-y1<8: raise ValueError('Dibuja una caja de al menos 8 x 8 pixeles.')
    return [x1,y1,x2,y2]

class Registro:
    def __init__(self,salida,dataset=None):
        self.out=Path(salida); m=self.out/'manifest_recortes.csv'
        self.hash=sha(m)
        self.rows=list(csv.DictReader(m.open(encoding='utf-8-sig',newline='')))
        d=json.loads((self.out/'revision_manual/decisiones.json').read_text(encoding='utf-8-sig'))
        if d['sha256_manifest']!=self.hash: raise ValueError('El manifiesto no coincide con las decisiones.')
        self.dec=d['decisiones']
        self.dataset=Path(dataset or json.loads((self.out/'configuracion.json').read_text(encoding='utf-8-sig'))['dataset'])
        if not self.dataset.is_dir(): raise ValueError('No existe el dataset: '+str(self.dataset))
        self.queue=[r for r in self.rows if self.dec.get(r['original'],{}).get('decision')=='CORREGIR']
        self.dest=self.out/'correcciones_manual'; self.dest.mkdir(exist_ok=True)
        self.path=self.dest/'correcciones.json'; self.fixed={}
        if self.path.exists():
            saved=json.loads(self.path.read_text(encoding='utf-8'))
            if saved['sha256_manifest']!=self.hash: raise ValueError('Las correcciones pertenecen a otro manifiesto.')
            self.fixed=saved['correcciones']
            for r in self.queue:
                v=self.fixed.get(r['original'])
                if v and v['decision_final']=='ACEPTAR' and not (self.out/v['recorte_final']).is_file():
                    raise ValueError('Falta un recorte corregido: '+v['recorte_final'])
    def save(self): atomic_json(self.path,{'sha256_manifest':self.hash,'correcciones':self.fixed})
    def resolve(self,r,image,box=None,exclude=False):
        v={'decision_final':'EXCLUIR' if exclude else 'ACEPTAR','fecha':datetime.now().isoformat(timespec='seconds'),'recorte_final':'','caja_xyxy':box,'nota':'Sin informacion suficiente' if exclude else 'Caja manual sobre original orientado por EXIF'}
        if not exclude:
            if image is None or box is None: raise ValueError('Primero dibuja la caja de la cabeza.')
            box=box_pixels(box[:2],box[2:],image.size); v['caja_xyxy']=box
            rel=Path('correcciones_manual/recortes')/r['individuo']/('%05d_cabeza_manual.jpg'%int(r['numero']))
            p=self.out/rel; p.parent.mkdir(parents=True,exist_ok=True)
            crop=image.crop(box); temp=p.with_suffix('.tmp'); crop.save(temp,format='JPEG',quality=95); temp.replace(p)
            v.update(recorte_final=rel.as_posix(),ancho_recorte=crop.width,alto_recorte=crop.height,sha256_original=sha(self.dataset/r['original']))
            # Panel reducido para compartir y comprobar visualmente la correccion.
            panel=image.copy(); ImageDraw.Draw(panel).rectangle(box,outline='lime',width=max(2,round(image.width/250)))
            panel.thumbnail((900,650)); small=crop.copy(); small.thumbnail((350,650))
            combined=Image.new('RGB',(panel.width+small.width+12,max(panel.height,small.height)), 'white')
            combined.paste(panel,(0,0)); combined.paste(small,(panel.width+12,0))
            pp=self.dest/'paneles'/('%05d.jpg'%int(r['numero'])); pp.parent.mkdir(exist_ok=True); combined.save(pp,quality=85)
        self.fixed[r['original']]=v; self.save()
    def export(self):
        fields=list(self.rows[0])+['decision_manual','decision_final','recorte_final','origen_recorte','caja_manual_xyxy']
        counts={}; records=[]
        for row in self.rows:
            r=dict(row); decision=self.dec.get(r['original'],{}).get('decision','PENDIENTE'); v=self.fixed.get(r['original']) if decision=='CORREGIR' else None
            r['decision_manual']=decision; r['decision_final']=v['decision_final'] if v else decision
            r['recorte_final']=(v['recorte_final'] if v else r['recorte']) if r['decision_final']=='ACEPTAR' else ''
            r['origen_recorte']='MANUAL' if v else 'DETECTOR'; r['caja_manual_xyxy']=json.dumps(v.get('caja_xyxy')) if v else ''
            counts[r['decision_final']]=counts.get(r['decision_final'],0)+1; records.append(r)
        with (self.dest/'manifest_corregido.csv').open('w',encoding='utf-8-sig',newline='') as f:
            writer=csv.DictWriter(f,fieldnames=fields); writer.writeheader(); writer.writerows(records)
        remaining=sum(r['original'] not in self.fixed for r in self.queue)
        atomic_json(self.dest/'resumen.json',{'casos_para_corregir':len(self.queue),'resueltos':len(self.queue)-remaining,'faltan':remaining,'totales':counts,'nota':'PENDIENTE de candidatos no equivale a aceptacion manual. No se generaron embeddings.'})
        self.save(); zpath=self.dest/'CORRECCIONES_PARA_COMPARTIR.zip'
        with zipfile.ZipFile(zpath,'w',zipfile.ZIP_DEFLATED) as z:
            for name in ['correcciones.json','manifest_corregido.csv','resumen.json']: z.write(self.dest/name,name)
            for p in sorted((self.dest/'paneles').glob('*.jpg')): z.write(p,'paneles/'+p.name)
        return zpath

class App:
    def __init__(self,reg):
        self.reg=reg; self.root=tk.Tk(); self.root.title('CiyFi - corregir cabezas'); self.root.geometry('1200x850')
        self.i=next((i for i,r in enumerate(reg.queue) if r['original'] not in reg.fixed),0); self.image=None; self.box=None; self.start=None
        self.status=tk.StringVar(); ttk.Label(self.root,textvariable=self.status).pack(pady=5)
        ttk.Label(self.root,text='Arrastra sobre la foto ORIGINAL para encerrar la cabeza y sus patrones. Incluye el borde que necesites.').pack()
        self.canvas=tk.Canvas(self.root,bg='#222',height=550); self.canvas.pack(fill='both',expand=True)
        self.canvas.bind('<Configure>',lambda e:self.draw()); self.canvas.bind('<ButtonPress-1>',self.begin); self.canvas.bind('<B1-Motion>',self.move); self.canvas.bind('<ButtonRelease-1>',self.release)
        self.preview=tk.Label(self.root); self.preview.pack()
        bar=ttk.Frame(self.root); bar.pack(pady=8)
        for title,action in [('Anterior',lambda:self.step(-1)),('GUARDAR CABEZA',lambda:self.finish(False)),('EXCLUIR',lambda:self.finish(True)),('Siguiente / dejar pendiente',lambda:self.step(1)),('Exportar ZIP',self.export)]:ttk.Button(bar,text=title,command=action).pack(side='left',padx=4)
        self.root.protocol('WM_DELETE_WINDOW',self.close); self.load()
    def load(self):
        self.box=None; self.image=None; self.preview.configure(image=''); self.start=None
        if not self.reg.queue:
            self.status.set('No hay casos marcados CORREGIR.'); return
        r=self.reg.queue[self.i]; v=self.reg.fixed.get(r['original']); self.box=v.get('caja_xyxy') if v and v['decision_final']=='ACEPTAR' else None
        done=sum(r['original'] in self.reg.fixed for r in self.reg.queue)
        self.status.set(f'{self.i+1}/{len(self.reg.queue)} | Foto {int(r["numero"]):05d} | {r["individuo"]} | Resueltos {done} | '+(v['decision_final'] if v else 'PENDIENTE'))
        try:self.image=read_image(self.reg.dataset/r['original'])
        except Exception as e:messagebox.showerror('No se pudo abrir',str(e))
        self.draw(); self.show_preview()
    def draw(self):
        self.canvas.delete('all')
        if self.image is None:return
        w=max(1,self.canvas.winfo_width()); h=max(1,self.canvas.winfo_height()); iw,ih=self.image.size
        dw=max(1,round(iw*min(w/iw,h/ih))); dh=max(1,round(ih*min(w/iw,h/ih)))
        self.sx=dw/iw; self.sy=dh/ih; self.ox=(w-dw)/2; self.oy=(h-dh)/2
        self.photo=ImageTk.PhotoImage(self.image.resize((dw,dh),Image.Resampling.LANCZOS)); self.canvas.create_image(self.ox,self.oy,image=self.photo,anchor='nw')
        if self.box:self.canvas.create_rectangle(self.ox+self.box[0]*self.sx,self.oy+self.box[1]*self.sy,self.ox+self.box[2]*self.sx,self.oy+self.box[3]*self.sy,outline='lime',width=3,tags='box')
    def point(self,e):return ((e.x-self.ox)/self.sx,(e.y-self.oy)/self.sy)
    def begin(self,e):
        if self.image is not None:self.start=self.point(e); self.box=None; self.preview.configure(image='')
    def move(self,e):
        if self.start is None:return
        try:self.box=box_pixels(self.start,self.point(e),self.image.size)
        except ValueError:self.box=None
        self.canvas.delete('box')
        if self.box:self.canvas.create_rectangle(self.ox+self.box[0]*self.sx,self.oy+self.box[1]*self.sy,self.ox+self.box[2]*self.sx,self.oy+self.box[3]*self.sy,outline='lime',width=3,tags='box')
    def release(self,e):self.move(e); self.start=None; self.show_preview()
    def show_preview(self):
        if self.image is not None and self.box:
            im=self.image.crop(self.box); im.thumbnail((450,160)); self.preview_photo=ImageTk.PhotoImage(im); self.preview.configure(image=self.preview_photo)
    def step(self,delta):
        if self.reg.queue:self.i=(self.i+delta)%len(self.reg.queue); self.load()
    def finish(self,exclude):
        if not self.reg.queue:return
        if exclude and not messagebox.askyesno('Excluir','Excluir esta fotografia de la identificacion? El original se conserva.'):return
        try:self.reg.resolve(self.reg.queue[self.i],self.image,self.box,exclude)
        except Exception as e:messagebox.showerror('No se guardo',str(e));return
        pending=[i for i,r in enumerate(self.reg.queue) if r['original'] not in self.reg.fixed]
        if pending:self.i=next((i for i in pending if i>self.i),pending[0]);self.load()
        else:self.load();self.export();messagebox.showinfo('Terminado','Todos los casos marcados estan resueltos. Comparte el ZIP exportado.')
    def export(self):
        try:p=self.reg.export();messagebox.showinfo('ZIP listo',str(p))
        except Exception as e:messagebox.showerror('Error al exportar',str(e))
    def close(self):
        try:self.reg.export()
        except Exception as e:messagebox.showerror('Error al exportar',str(e));return
        self.root.destroy()
    def run(self):self.root.mainloop()

if __name__=='__main__':
    try:App(Registro(sys.argv[1],sys.argv[2] if len(sys.argv)>2 and sys.argv[2] else None)).run()
    except Exception as e:print('ERROR:',e);sys.exit(1)

'@ | & $python - $Salida $Dataset
if ($LASTEXITCODE -ne 0) { throw 'No se pudo ejecutar el corrector; revisa el error anterior.' }
