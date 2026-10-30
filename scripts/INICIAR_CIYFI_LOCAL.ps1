param([string]$Proyecto = '')
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Proyecto)) { $Proyecto = $PSScriptRoot }
$python = Join-Path $Proyecto '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { throw 'No existe .venv\Scripts\python.exe. Guarda este lanzador en zproyecto3_0.' }
$env:PYTHONUTF8 = '1'
$env:PYTHONIOENCODING = 'utf-8'
& $python -c "import tkinter, torch, torchvision, numpy; from PIL import Image, ImageTk; print('Dependencias disponibles. Abriendo CIYFI local...')"
if ($LASTEXITCODE -ne 0) { throw 'Falta una dependencia. Comparte la salida de la terminal.' }
$carpeta = Join-Path $Proyecto 'herramientas3_0'
New-Item -ItemType Directory -Path $carpeta -Force | Out-Null
$programa = Join-Path $carpeta 'CIYFI_LOCAL.py'
$codigo = @'
import csv,hashlib,json,math,os,queue,sqlite3,sys,threading,traceback,uuid,zipfile
from pathlib import Path,PureWindowsPath
from datetime import datetime
from collections import defaultdict
import numpy as np
from PIL import Image,ImageOps,ImageTk
import tkinter as tk
from tkinter import ttk,filedialog,messagebox

MODEL_HASH='6d00246653620c1410f65df3376317ee6bc1d9e8fbf9e1f4abf5ae8889f845ac'
DETECTOR_HASH='71c02f61f4eb24b36a48213466d9ff1dbd9d50b1fd431c5a708053f3ccaa2ed5'
def require(condition,message):
    if not condition:raise ValueError(message)
def load(path):return json.loads(Path(path).read_text(encoding='utf-8-sig'))
def sha(path):
    h=hashlib.sha256()
    with Path(path).open('rb') as f:
        for block in iter(lambda:f.read(1024*1024),b''):h.update(block)
    return h.hexdigest()
def read_csv(path):
    with Path(path).open(encoding='utf-8-sig',newline='') as f:return list(csv.DictReader(f))
def safe(base,rel):
    p=(base/rel).resolve();require(p.is_relative_to(base.resolve()),'Ruta fuera de la galeria.');return p

def crop_root(project,old):
    parts=PureWindowsPath(old).parts
    if 'recortes3_0' in parts:
        p=project.joinpath(*parts[parts.index('recortes3_0'):])
        if p.is_dir():return p
    p=Path(old);require(p.is_dir(),'No se encontro recortes3_0 en el proyecto.');return p

def open_image(path):
    with Image.open(path) as f:
        f.seek(0);im=ImageOps.exif_transpose(f).convert('RGB');im.load();return im

def letterbox(im):
    im=ImageOps.contain(im,(224,224),method=Image.Resampling.BILINEAR)
    out=Image.new('RGB',(224,224),(124,116,104));out.paste(im,((224-im.width)//2,(224-im.height)//2));return out

def unit(a):
    a=np.asarray(a,dtype=np.float32);norm=np.linalg.norm(a,axis=-1,keepdims=True)
    require(np.isfinite(a).all() and np.all(norm>1e-12),'Embeddings invalidos.');return np.ascontiguousarray(a/norm)

def clamp_box(box,width,height):
    x1,y1,x2,y2=box;x1,x2=sorted((float(x1),float(x2)));y1,y2=sorted((float(y1),float(y2)))
    result=(max(0,int(math.floor(x1))),max(0,int(math.floor(y1))),min(width,int(math.ceil(x2))),min(height,int(math.ceil(y2))))
    require(result[2]-result[0]>=4 and result[3]-result[1]>=4,'Selecciona una caja mas grande dentro de la imagen.');return result

def identity_top5(scores,rows):
    groups=defaultdict(list)
    for i,r in enumerate(rows):groups[r['individuo']].append(i)
    ranked=[]
    for identity,indices in groups.items():
        best=max(indices,key=lambda i:(float(scores[i]),-i));ranked.append({'individuo':identity,'similitud_coseno':float(scores[best]),'indice_referencia':best,'referencia':rows[best]['recorte'],'cantidad_fotos':len(indices)})
    return sorted(ranked,key=lambda r:(-r['similitud_coseno'],r['individuo']))[:5]

def find_final_evaluation(project):
    matches=[]
    for folder in (project/'reid3_0').glob('evaluacion_final_*'):
        try:
            protocol=load(folder/'protocolo_fijado.json')
            if (load(folder/'estado.json').get('estado')=='COMPLETO'
                and protocol.get('modelo_sha256')==MODEL_HASH
                and protocol.get('ciclo_refuerzo')==5
                and (folder/'galeria_entrenamiento.csv').is_file()
                and (folder/'cache_galeria').is_dir()
                and (folder/'configuracion.json').is_file()):matches.append(folder)
        except (OSError,ValueError,KeyError):continue
    require(bool(matches),'No se encontro una evaluacion final completa y compatible en reid3_0. Conserva su carpeta y cache_galeria.')
    # Preferencia por la evaluacion mas recientemente completada del mismo modelo.
    return max(matches,key=lambda folder:((folder/'estado.json').stat().st_mtime,folder.name))

class Engine:
    def __init__(self,project,notify):
        import torch
        from torchvision.models import resnet50
        from torchvision.transforms import Compose,ToTensor,Normalize
        self.project=project;self.torch=torch;torch.set_num_threads(4)
        root=find_final_evaluation(project)
        cfg=load(root/'configuracion.json');protocol=load(root/'protocolo_fijado.json')
        require(load(root/'estado.json')['estado']=='COMPLETO','La evaluacion final no esta completa.')
        require(protocol['modelo_sha256']==MODEL_HASH,'Evaluacion de otro modelo.')
        self.weights=project/'runs3_0/reid_refuerzo_d2fc49cf7d5b15b4/mejor.pt'
        require(sha(self.weights)==MODEL_HASH,'El modelo de reidentificacion cambio.');self.model_hash=MODEL_HASH
        self.crops=crop_root(project,cfg['carpeta_recortes']);gallery=root/'galeria_entrenamiento.csv';self.rows=read_csv(gallery)
        require(len(self.rows)==4495 and len({r['individuo'] for r in self.rows})==1001,'Galeria incompleta.')
        require(sha(gallery)==protocol['train_sha256'],'Galeria modificada o fuera del protocolo de prueba.')
        arrays=[]
        for offset in range(0,len(self.rows),128):
            a=np.load(root/'cache_galeria'/f'{offset:05d}.npy',allow_pickle=False)
            require(a.shape==(min(128,len(self.rows)-offset),256),'Bloque de galeria incompatible.');arrays.append(a)
        self.g=unit(np.concatenate(arrays));self.gallery_hash=sha(gallery)
        notify('Comprobando los recortes de la galeria...')
        for i,r in enumerate(self.rows,1):
            require(sha(safe(self.crops,r['recorte']))==r['sha256_archivo'],'Recorte modificado: '+r['recorte'])
            if i%1000==0:notify(f'Galeria comprobada: {i}/4495')
        self.model=resnet50(weights=None);self.model.fc=torch.nn.Linear(2048,256)
        state=torch.load(self.weights,map_location='cpu',weights_only=True);require(state['ciclo_refuerzo']==5,'Checkpoint incorrecto.');self.model.load_state_dict(state['modelo']);self.model.eval()
        self.transform=Compose([ToTensor(),Normalize([.485,.456,.406],[.229,.224,.225])])
        self.yolo=None;self.detector=project/'runs3_0/ciyfi_refuerzo_20261003_231304_294942/entrenamiento/weights/best.pt'
        self.faiss_index=None
        # FAISS es opcional; la busqueda exacta conserva el mismo maximo por identidad.
        try:
            import faiss
            self.faiss_index=faiss.IndexFlatIP(256);self.faiss_index.add(self.g)
        except ImportError:pass
        self.history=project/'consultas3_0';self.history.mkdir(exist_ok=True);init_db(self.history/'historial.sqlite')
    def detect(self,im):
        require(self.detector.is_file(),'No se encontro el detector local. Dibuja la caja manualmente.')
        require(sha(self.detector)==DETECTOR_HASH,'El detector local cambio. Puedes dibujar la caja manualmente.')
        if self.yolo is None:
            try:from ultralytics import YOLO
            except ImportError:raise ValueError('Ultralytics no esta disponible. Dibuja la caja manualmente.')
            self.yolo=YOLO(str(self.detector))
        r=self.yolo.predict(source=im,device='cpu',imgsz=640,conf=.25,max_det=10,save=False,verbose=False)[0]
        boxes=[]
        if r.boxes is not None:
            for coords,confidence in zip(r.boxes.xyxy.cpu().numpy(),r.boxes.conf.cpu().numpy()):
                try:box=clamp_box(coords,im.width,im.height)
                except ValueError:continue
                boxes.append({'caja':box,'puntuacion_detector':float(confidence)})
        return sorted(boxes,key=lambda b:-b['puntuacion_detector'])
    def search(self,im):
        with self.torch.inference_mode():
            x=self.transform(letterbox(im)).unsqueeze(0);q=unit(self.model(x).cpu().numpy())
        if self.faiss_index is None:scores=(q@self.g.T)[0]
        else:
            distances,indices=self.faiss_index.search(q,len(self.rows));scores=np.empty(len(self.rows),dtype=np.float32);scores[indices[0]]=distances[0]
        return identity_top5(scores,self.rows),scores
    def references(self,identity,scores):
        ids=[i for i,r in enumerate(self.rows) if r['individuo']==identity]
        return sorted(ids,key=lambda i:(-float(scores[i]),i))[:18]


def init_db(path):
    with sqlite3.connect(path) as db:
        db.execute('CREATE TABLE IF NOT EXISTS revisiones (id TEXT PRIMARY KEY, fecha TEXT NOT NULL, decision TEXT NOT NULL, individuo TEXT, valoracion_0_10 INTEGER, porcentaje_humano INTEGER, detalles_json TEXT NOT NULL)')

def validate_review(decision,selected,rating,rated,patterns):
    require(decision in ('Coincidencia confirmada','Ninguna coincide','No estoy seguro','Imagen no evaluable'),'Selecciona una decision.')
    if decision=='Coincidencia confirmada':
        require(bool(selected),'Selecciona el candidato que confirmas.');require(patterns,'Compara los patrones visibles antes de confirmar.');require(rated,'Selecciona el candidato y elige una valoracion de 0 a 10 antes de confirmar.')
    require(0<=rating<=10,'Valoracion fuera de escala.')
    return (rating,rating*10) if selected and rated else (None,None)

def save_review(engine,original,crop,bbox,source_path,results,selected,decision,rating,rated,patterns,notes,operator):
    human,percent=validate_review(decision,selected,rating,rated,patterns)
    require(not selected or selected in {r['individuo'] for r in results},'Candidato seleccionado no pertenece a esta consulta.')
    uid=datetime.now().strftime('%Y%m%d_%H%M%S_')+uuid.uuid4().hex[:8];folder=engine.history/uid;folder.mkdir()
    try:
        original.save(folder/'consulta.png')
        if crop is not None:crop.save(folder/'cabeza.png')
        record={'id':uid,'fecha':datetime.now().astimezone().isoformat(),'archivo_origen':str(source_path),'consulta_sha256':sha(folder/'consulta.png'),'cabeza_sha256':sha(folder/'cabeza.png') if crop is not None else None,'caja_xyxy':list(bbox) if bbox else None,'decision':decision,'candidato_seleccionado':selected or None,'identidad_confirmada_por_revisor':selected if decision=='Coincidencia confirmada' else None,'valoracion_humana_0_10':human,'porcentaje_valoracion_humana':percent,'interpretacion_escala':'Valoracion subjetiva del revisor; no es probabilidad calibrada ni precision del modelo.','patrones_comparados':patterns,'revisor':operator.strip(),'observaciones':notes.strip(),'modelo_sha256':engine.model_hash,'galeria_sha256':engine.gallery_hash,'top5':results,'dataset_modificado':False}
        text=json.dumps(record,ensure_ascii=False,indent=2);(folder/'revision.json').write_text(text,encoding='utf-8')
        with sqlite3.connect(engine.history/'historial.sqlite') as db:
            db.execute('INSERT INTO revisiones VALUES (?,?,?,?,?,?,?)',(uid,record['fecha'],decision,selected or None,human,percent,text))
        return uid
    except Exception:
        # No deja imagenes sueltas como si fueran una revision completada.
        import shutil
        shutil.rmtree(folder,ignore_errors=True);raise

class App:
    def __init__(self,root,project):
        self.root=root;self.project=project;self.events=queue.Queue();self.engine=None;self.busy=True;self.original=None;self.crop=None;self.box=None;self.results=[];self.scores=None;self.detections=[];self.photos=[];self.drag=None;self.version=0;self.saved=False;self.batch_files=[];self.batch_index=-1;self.batch_folder=None;self.decision_buttons=[]
        root.title('CIYFI 3.0 | Consulta y revision humana');root.geometry('1200x760');root.minsize(980,620)
        style=ttk.Style(root);style.theme_use('clam');style.configure('TButton',padding=4);style.configure('Title.TLabel',font=('Segoe UI',17,'bold'))
        shell=ttk.Frame(root,padding=12);shell.pack(fill='both',expand=True)
        ttk.Label(shell,text='CIYFI | Buscar y comparar tortugas',style='Title.TLabel').pack(anchor='w')
        ttk.Label(shell,text='Cinco candidatos para revision humana. Prueba de esta version: Top-1 32.94% | Top-5 50.54%.').pack(anchor='w')
        self.status=tk.StringVar(value='Cargando modelo y galeria...');ttk.Label(shell,textvariable=self.status,foreground='#155e75').pack(anchor='w',pady=(6,8))
        bar=ttk.Frame(shell);bar.pack(fill='x');self.controls=[]
        for label,command in [('1. Seleccionar carpeta',self.choose_folder),('Foto suelta',self.choose),('2. Detectar cabeza',self.detect),('Usar imagen ya recortada',self.full_crop),('3. Buscar candidatos',self.search)]:
            b=ttk.Button(bar,text=label,command=command);b.pack(side='left',padx=(0,6));self.controls.append(b)
        self.box_choice=ttk.Combobox(bar,state='disabled',width=22);self.box_choice.pack(side='left');self.box_choice.bind('<<ComboboxSelected>>',self.choose_detection)
        queuebar=ttk.Frame(shell);queuebar.pack(fill='x',pady=3);self.batch_label=tk.StringVar(value='Sin carpeta seleccionada');ttk.Label(queuebar,textvariable=self.batch_label).pack(side='left');self.cropped_mode=tk.BooleanVar(value=False);ttk.Checkbutton(queuebar,text='Carpeta con cabezas ya recortadas',variable=self.cropped_mode).pack(side='left',padx=8)
        ttk.Label(shell,text='Para corregir el recorte, arrastra una caja sobre la foto. Cualquier cambio requiere buscar de nuevo.').pack(anchor='w',pady=5)
        panes=ttk.Panedwindow(shell,orient='horizontal');panes.pack(fill='both',expand=True)
        left=ttk.Frame(panes);right=ttk.Frame(panes);panes.add(left,weight=1);panes.add(right,weight=1);root.after(300,lambda:panes.sashpos(0,max(300,panes.winfo_width()//2)))
        self.canvas=tk.Canvas(left,height=120,bg='#172b35',highlightthickness=0);self.canvas.pack(fill='both',expand=True);self.canvas.bind('<Configure>',lambda e:self.draw_original());self.canvas.bind('<ButtonPress-1>',self.start_drag);self.canvas.bind('<B1-Motion>',self.move_drag);self.canvas.bind('<ButtonRelease-1>',self.end_drag)
        cropbar=ttk.Frame(left);cropbar.pack(fill='x',pady=4);self.crop_label=ttk.Label(cropbar);self.crop_label.pack(side='left');self.crop_info=tk.StringVar(value='Sin cabeza seleccionada');ttk.Label(cropbar,textvariable=self.crop_info,wraplength=270).pack(side='left',padx=10)
        ttk.Label(right,text='Selecciona un individuo; puedes abrir mas referencias.').pack(anchor='w')
        area=ttk.Frame(right);area.pack(fill='both',expand=True);self.cards_canvas=tk.Canvas(area,height=120,highlightthickness=0);scroll=ttk.Scrollbar(area,orient='vertical',command=self.cards_canvas.yview);self.cards_canvas.configure(yscrollcommand=scroll.set);scroll.pack(side='right',fill='y');self.cards_canvas.pack(side='left',fill='both',expand=True)
        self.cards=ttk.Frame(self.cards_canvas);self.cards_window=self.cards_canvas.create_window((0,0),window=self.cards,anchor='nw');self.cards.bind('<Configure>',lambda e:self.cards_canvas.configure(scrollregion=self.cards_canvas.bbox('all')));self.cards_canvas.bind('<Configure>',lambda e:self.cards_canvas.itemconfigure(self.cards_window,width=e.width));self.cards_canvas.bind('<Enter>',lambda e:self.root.bind_all('<MouseWheel>',self.wheel));self.cards_canvas.bind('<Leave>',lambda e:self.root.unbind_all('<MouseWheel>'))
        decisionbar=ttk.LabelFrame(shell,text='4. Registrar tu revision',padding=8);decisionbar.pack(side='bottom',fill='x',pady=(6,0),before=panes)
        row=ttk.Frame(decisionbar);row.pack(fill='x');self.selected=tk.StringVar(value='');self.decision=tk.StringVar(value='')
        self.operator=tk.StringVar();ttk.Label(row,text='Revisor (opcional):').pack(side='left',padx=(10,0));ttk.Entry(row,textvariable=self.operator,width=23).pack(side='left',padx=6)
        self.rating=tk.IntVar(value=0);self.rating_text=tk.StringVar(value='0/10 = 0% de valoracion humana');self.rated=tk.BooleanVar(value=False);self.patterns=tk.BooleanVar(value=False)
        rate=ttk.Frame(decisionbar);rate.pack(fill='x',pady=3);ttk.Label(rate,text='Valoracion (0 a 10):').pack(side='left');self.rating_choice=ttk.Combobox(rate,values=list(range(11)),state='readonly',width=5);self.rating_choice.pack(side='left',padx=6);self.rating_choice.bind('<<ComboboxSelected>>',self.pick_rating);ttk.Label(rate,textvariable=self.rating_text).pack(side='left',padx=8)
        ttk.Label(decisionbar,text='La valoracion es tu opinion visual; no es una probabilidad de identidad.',foreground='#8a4600').pack(anchor='w')
        note=ttk.Frame(decisionbar);note.pack(fill='x',pady=3);ttk.Label(note,text='Observaciones:').pack(side='left');self.notes=ttk.Entry(note);self.notes.pack(side='left',fill='x',expand=True,padx=6)
        foot=ttk.Frame(decisionbar);foot.pack(fill='x')
        for label,decision in [('Confirmar candidato','Coincidencia confirmada'),('Ninguna coincide','Ninguna coincide'),('No estoy seguro','No estoy seguro'),('Imagen no evaluable','Imagen no evaluable')]:
            button=ttk.Button(foot,text=label,command=lambda d=decision:self.choose_decision(d));button.pack(side='left',padx=(0,5));self.decision_buttons.append(button)
        ttk.Label(decisionbar,textvariable=self.decision,foreground='#155e75').pack(anchor='w',pady=2)
        historybar=ttk.Frame(decisionbar);historybar.pack(fill='x',pady=(4,0));self.save_button=ttk.Button(historybar,text='GUARDAR Y SEGUIR',command=self.save);self.save_button.pack(side='left',padx=(0,8));self.next_button=ttk.Button(historybar,text='SIGUIENTE SIN GUARDAR',command=self.next_photo);self.next_button.pack(side='left',padx=(0,8));self.controls.append(self.next_button);ttk.Button(historybar,text='Exportar historial a CSV',command=self.export).pack(side='left');ttk.Button(historybar,text='Abrir historial',command=self.open_history).pack(side='left',padx=8)
        root.protocol('WM_DELETE_WINDOW',self.close);self.set_busy(True);root.after(100,self.poll);self.work('init',lambda:Engine(project,lambda msg:self.events.put(('status',msg))))
    def wheel(self,e):self.cards_canvas.yview_scroll(int(-e.delta/120),'units')
    def set_busy(self,value):
        self.busy=value
        for b in self.controls:b.configure(state='disabled' if value or not self.engine else 'normal')
        for i,b in enumerate(self.decision_buttons):b.configure(state='normal' if not value and self.original is not None and not self.saved and (i==3 or bool(self.results)) else 'disabled')
        self.save_button.configure(state='normal' if not value and self.original is not None and not self.saved and bool(self.decision.get()) else 'disabled')
        self.rating_choice.configure(state='readonly' if not value and bool(self.selected.get()) else 'disabled')
        self.box_choice.configure(state='readonly' if not value and self.detections else 'disabled')
    def work(self,kind,fn):
        self.set_busy(True)
        def worker():
            try:self.events.put((kind,fn()))
            except Exception as e:self.events.put(('error',(str(e),traceback.format_exc())))
        threading.Thread(target=worker,daemon=True).start()
    def poll(self):
        try:
            while True:
                kind,result=self.events.get_nowait()
                if kind=='status':self.status.set(result);continue
                self.set_busy(False)
                try:
                    if kind=='error':
                        self.status.set('Operacion no completada.');messagebox.showerror('CIYFI',result[0]);print(result[1],flush=True)
                    elif kind=='init':self.engine=result;self.set_busy(False);self.status.set('Listo. Galeria: 4495 fotos de 1001 individuos | CPU | '+('FAISS exacto' if result.faiss_index is not None else 'Coseno exacto'))
                    elif kind=='photo':
                        self.source_path,self.original=result;self.reset_image();self.draw_original();self.set_busy(False);self.status.set('Foto cargada. Detecta la cabeza o dibuja una caja.')
                        if self.batch_files:
                            if self.cropped_mode.get():self.full_crop();self.search()
                            else:self.detect()

                    elif kind=='detect':
                        self.detections=result;self.box_choice['values']=[f'Caja {i+1} | detector {b["puntuacion_detector"]:.2f}' for i,b in enumerate(result)]
                        if result:self.box_choice.current(0);self.set_crop(result[0]['caja']);self.set_busy(False);self.status.set(f'{len(result)} cajas detectadas. Verifica la cabeza antes de confirmar.');self.search() if self.batch_files else None
                        else:self.status.set('Sin deteccion. Dibuja una caja alrededor de la cabeza.')
                    elif kind=='search':self.results,self.scores=result;self.render_cards();self.status.set('Selecciona un candidato y compara patrones. Puedes elegir ninguna coincidencia.');self.set_busy(False)
                    elif kind=='save':
                        self.saved=True;self.set_busy(False);self.status.set('Revision guardada: '+result)
                        if self.batch_files:self.next_photo()

                except Exception as e:messagebox.showerror('CIYFI',str(e));traceback.print_exc()
        except queue.Empty:pass
        self.root.after(100,self.poll)
    def clear_results(self):
        self.results=[];self.scores=None;self.selected.set('');self.rating.set(0);self.rating_choice.set('');self.rating_text.set('Selecciona un candidato y elige una valoracion.');self.rated.set(False);self.patterns.set(False);self.decision.set('');self.saved=False
        for w in self.cards.winfo_children():w.destroy()
        self.photos=[];self.save_button.configure(state='disabled')
        for b in self.decision_buttons:b.configure(state='disabled')
    def reset_image(self):
        self.version+=1;self.clear_results();self.crop=None;self.box=None;self.detections=[];self.box_choice['values']=[];self.box_choice.set('');self.box_choice.configure(state='disabled');self.crop_label.configure(image='');self.crop_info.set('Sin cabeza seleccionada');self.notes.delete(0,'end')
    def choose(self):
        if self.busy:return
        path=filedialog.askopenfilename(title='Seleccionar fotografia',filetypes=[('Imagenes','*.jpg *.jpeg *.png *.bmp *.tif *.tiff *.webp *.mpo'),('Todos','*.*')])
        if path:
            self.batch_files=[];self.batch_index=-1;self.batch_label.set('Foto suelta');self.status.set('Leyendo foto...');self.work('photo',lambda:(Path(path),open_image(path)))
    def choose_folder(self):
        if self.busy:return
        folder=filedialog.askdirectory(title='Carpeta de fotos para revisar (incluye subcarpetas)')
        if not folder:return
        extensions={'.jpg','.jpeg','.png','.bmp','.tif','.tiff','.webp','.mpo'}
        try:files=sorted((p for p in Path(folder).rglob('*') if p.is_file() and p.suffix.lower() in extensions),key=lambda p:str(p).casefold())
        except OSError as error:return messagebox.showerror('Carpeta',str(error))
        if not files:return messagebox.showinfo('Carpeta','No se encontraron imagenes.')
        self.batch_files=files;self.batch_folder=Path(folder);self.batch_index=-1;self.next_photo()
    def next_photo(self):
        if self.busy or not self.batch_files:return
        index=self.batch_index+1
        if index>=len(self.batch_files):
            self.batch_label.set(f'Carpeta terminada: {len(self.batch_files)} fotos recorridas. Consulta las decisiones en el historial.');self.status.set('Fin de la carpeta. Puedes exportar el historial a CSV.');return
        self.batch_index=index;path=self.batch_files[index]
        self.batch_label.set(f'Foto {index+1}/{len(self.batch_files)} | {path.relative_to(self.batch_folder)}')
        self.original=None;self.reset_image();self.draw_original();self.status.set('Leyendo foto...')
        self.work('photo',lambda:(path,open_image(path)))
    def draw_original(self):
        self.canvas.delete('all')
        if self.original is None:return
        width=max(20,self.canvas.winfo_width());height=max(20,self.canvas.winfo_height());display=ImageOps.contain(self.original,(width,height));self.display_photo=ImageTk.PhotoImage(display);self.dx=(width-display.width)/2;self.dy=(height-display.height)/2;self.sx=display.width/self.original.width;self.sy=display.height/self.original.height
        self.canvas.create_image(self.dx,self.dy,image=self.display_photo,anchor='nw')
        if self.box:
            a,b,c,d=self.box;self.canvas.create_rectangle(self.dx+a*self.sx,self.dy+b*self.sy,self.dx+c*self.sx,self.dy+d*self.sy,outline='#2ee59d',width=3)
    def point(self,e):
        return (max(0,min(self.original.width,(e.x-self.dx)/self.sx)),max(0,min(self.original.height,(e.y-self.dy)/self.sy)))
    def start_drag(self,e):
        if self.busy or self.original is None:return
        self.drag=self.point(e);self.canvas.delete('draft')
    def move_drag(self,e):
        if self.drag is None or self.busy:return
        x,y=self.point(e);a,b=self.drag;self.canvas.delete('draft');self.canvas.create_rectangle(self.dx+a*self.sx,self.dy+b*self.sy,self.dx+x*self.sx,self.dy+y*self.sy,outline='#ffd166',width=3,tags='draft')
    def end_drag(self,e):
        if self.drag is None or self.busy:return
        a,b=self.drag;self.drag=None;c,d=self.point(e)
        try:self.set_crop(clamp_box((a,b,c,d),self.original.width,self.original.height));self.status.set('Recorte manual seleccionado. Pulsa Buscar candidatos.')
        except ValueError as error:self.canvas.delete('draft');self.status.set(str(error))
    def set_crop(self,box):
        self.clear_results();self.box=clamp_box(box,self.original.width,self.original.height);self.crop=self.original.crop(self.box);thumb=ImageOps.contain(self.crop,(90,65));self.crop_photo=ImageTk.PhotoImage(thumb);self.crop_label.configure(image=self.crop_photo);self.set_busy(False);self.crop_info.set(f'Cabeza seleccionada: {self.crop.width} x {self.crop.height} px.\nComprueba que se vean las escamas.');self.draw_original()
    def full_crop(self):
        if self.original is None:return messagebox.showinfo('Foto','Carga primero una foto.')
        self.set_crop((0,0,self.original.width,self.original.height));self.status.set('Usando toda la imagen como cabeza. Verifica que ya sea un recorte.')
    def detect(self):
        if self.original is None:return messagebox.showinfo('Foto','Carga primero una foto.')
        self.status.set('Detectando cabeza...');im=self.original.copy();self.work('detect',lambda:self.engine.detect(im))
    def choose_detection(self,e=None):
        if not self.busy and self.box_choice.current()>=0:self.set_crop(self.detections[self.box_choice.current()]['caja'])
    def search(self):
        if self.crop is None:return messagebox.showinfo('Recorte','Selecciona la cabeza antes de buscar.')
        self.clear_results();im=self.crop.copy();self.status.set('Comparando con la galeria...');self.work('search',lambda:self.engine.search(im))
    def select_candidate(self):
        self.rating.set(0);self.rating_choice.set('');self.rating_text.set('Elige una valoracion de 0 a 10.');self.rated.set(False);self.patterns.set(False);self.decision.set('');self.set_busy(False)
    def pick_rating(self,event=None):
        if self.busy or not self.selected.get():return
        value=int(self.rating_choice.get());self.rating.set(value);self.rated.set(True);self.rating_text.set(f'{value}/10 = {value*10}% de valoracion humana')
    def render_cards(self):
        for w in self.cards.winfo_children():w.destroy()
        self.photos=[]
        for rank,r in enumerate(self.results,1):
            frame=ttk.LabelFrame(self.cards,text=f'Top {rank} | {r["individuo"]}',padding=6);frame.pack(fill='x',pady=4)
            try:im=ImageOps.contain(open_image(safe(self.engine.crops,r['referencia'])),(140,125));photo=ImageTk.PhotoImage(im);self.photos.append(photo);ttk.Label(frame,image=photo).pack(side='left')
            except Exception:ttk.Label(frame,text='No se pudo mostrar la referencia').pack(side='left')
            text=ttk.Frame(frame);text.pack(side='left',padx=10);ttk.Label(text,text=f'Similitud coseno: {r["similitud_coseno"]:.4f}\n{r["cantidad_fotos"]} fotos de este individuo en galeria').pack(anchor='w');ttk.Radiobutton(text,text='Seleccionar este candidato',variable=self.selected,value=r['individuo'],command=self.select_candidate).pack(anchor='w',pady=4);ttk.Button(text,text='Ver mas referencias',command=lambda identity=r['individuo']:self.show_refs(identity)).pack(anchor='w')
        self.cards_canvas.yview_moveto(0)
    def show_refs(self,identity):
        if self.busy or self.scores is None:return
        window=tk.Toplevel(self.root);window.title('Comparar referencias | '+identity);window.geometry('980x740');photos=[];window.photos=photos
        ttk.Label(window,text='Consulta a la izquierda. Referencias de entrenamiento ordenadas por similitud.',padding=8).pack(anchor='w')
        body=ttk.Frame(window);body.pack(fill='both',expand=True);left=ttk.Frame(body);left.pack(side='left',fill='y',padx=8)
        photo=ImageTk.PhotoImage(ImageOps.contain(self.crop,(250,420)));photos.append(photo);ttk.Label(left,image=photo).pack();ttk.Label(left,text='Consulta actual').pack()
        right=tk.Canvas(body,highlightthickness=0);scroll=ttk.Scrollbar(body,orient='vertical',command=right.yview);right.configure(yscrollcommand=scroll.set);scroll.pack(side='right',fill='y');right.pack(fill='both',expand=True);grid=ttk.Frame(right);right.create_window((0,0),window=grid,anchor='nw');grid.bind('<Configure>',lambda e:right.configure(scrollregion=right.bbox('all')))
        for n,i in enumerate(self.engine.references(identity,self.scores)):
            r=self.engine.rows[i];frame=ttk.Frame(grid,padding=7);frame.grid(row=n//3,column=n%3)
            try:im=open_image(safe(self.engine.crops,r['recorte']));photo=ImageTk.PhotoImage(ImageOps.contain(im,(180,180)));photos.append(photo);ttk.Label(frame,image=photo).pack()
            except Exception:ttk.Label(frame,text='Referencia no disponible').pack()
            ttk.Label(frame,text=f'Foto {r["numero"]} | coseno {self.scores[i]:.4f}\n{r["revision_calidad"]}',wraplength=185).pack()
    def choose_decision(self,decision):
        if self.busy or self.original is None or self.saved:return
        if decision!='Imagen no evaluable' and not self.results:return
        self.decision.set(decision);self.patterns.set(decision=='Coincidencia confirmada')
        if decision=='Imagen no evaluable':self.selected.set('');self.rated.set(False)
        self.set_busy(False);self.status.set('Decision elegida. Pulsa GUARDAR Y SEGUIR para registrarla.')
    def save(self):
        if self.busy or self.original is None or self.saved:return
        if self.decision.get()!='Imagen no evaluable' and not self.results:return messagebox.showinfo('Revision','Busca candidatos antes de guardar esta decision.')
        try:validate_review(self.decision.get(),self.selected.get(),self.rating.get(),self.rated.get(),self.patterns.get())
        except ValueError as e:return messagebox.showinfo('Revision incompleta',str(e))
        args=(self.engine,self.original.copy(),self.crop.copy() if self.crop is not None else None,tuple(self.box) if self.box else None,self.source_path,[dict(r) for r in self.results],self.selected.get(),self.decision.get(),self.rating.get(),self.rated.get(),self.patterns.get(),self.notes.get(),self.operator.get())
        self.work('save',lambda:save_review(*args))
    def open_history(self):
        if self.engine is not None:os.startfile(str(self.engine.history))
    def export(self):
        if self.busy or self.engine is None:return
        path=filedialog.asksaveasfilename(title='Exportar historial',initialdir=str(self.engine.history),initialfile='historial_revision.csv',defaultextension='.csv',filetypes=[('CSV','*.csv')])
        if not path:return
        try:
            with sqlite3.connect(self.engine.history/'historial.sqlite') as db:rows=db.execute('SELECT id,fecha,decision,individuo,valoracion_0_10,porcentaje_humano,detalles_json FROM revisiones ORDER BY fecha').fetchall()
            with Path(path).open('w',encoding='utf-8-sig',newline='') as f:
                writer=csv.writer(f);writer.writerow(['id','fecha','decision','candidato_seleccionado','valoracion_humana_0_10','porcentaje_subjetivo','detalles_json']);writer.writerows(rows)
            messagebox.showinfo('Exportado',f'{len(rows)} revisiones exportadas.\n{path}')
        except Exception as e:messagebox.showerror('Exportacion',str(e))
    def close(self):
        if self.busy and not messagebox.askyesno('Cerrar','Hay una operacion en curso. ¿Cerrar la herramienta?'):return
        self.root.destroy()

def main():
    project=Path(sys.argv[1]).resolve();root=tk.Tk();App(root,project);root.mainloop()
if __name__=='__main__':main()

'@
[System.IO.File]::WriteAllText($programa, $codigo, (New-Object System.Text.UTF8Encoding($false)))
& $python $programa $Proyecto
if ($LASTEXITCODE -ne 0) { throw 'La herramienta se cerro con un error. Comparte la salida de la terminal.' }
