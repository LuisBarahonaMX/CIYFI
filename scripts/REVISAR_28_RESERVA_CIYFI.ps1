param([string]$Proyecto = '', [string]$PythonExe = '')
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Proyecto)) { $Proyecto = $PSScriptRoot }
if ([string]::IsNullOrWhiteSpace($PythonExe)) { $PythonExe = Join-Path $Proyecto '.venv\Scripts\python.exe' }
if (-not (Test-Path -LiteralPath $PythonExe -PathType Leaf)) { throw 'No se encontro Python. Guarda el script en zproyecto3_0 o indica -PythonExe.' }
$env:PYTHONUTF8 = '1'
$env:PYTHONIOENCODING = 'utf-8'
& $PythonExe -c "import tkinter; from PIL import Image, ImageTk"
if ($LASTEXITCODE -ne 0) { throw 'Se necesitan tkinter y Pillow. Comparte el error.' }
$carpeta = Join-Path $Proyecto 'herramientas3_0'
New-Item -ItemType Directory -Force -Path $carpeta | Out-Null
$programa = Join-Path $carpeta 'REVISAR_28_RESERVA.py'
$codigo = @'
import hashlib,json,os,sys,zipfile,traceback
from pathlib import Path
from datetime import datetime
import tkinter as tk
from tkinter import ttk,messagebox
from PIL import Image,ImageOps,ImageTk
MANIFEST=[{'original': 'individuo 0001/img01_ind_cm0001.jpg', 'individuo': 'individuo 0001', 'fecha_exif': '2020-08-10T03:37:47', 'dia_operativo': '2020-08-09', 'sesion_candidata': 'R001', 'sha256_original': '0d760ea9d7cf50c84b00309ccfba32033d3c5ec9e157f2c2852d2758e691d271', 'consultada_en_historial_40': True, 'motivo_anterior': 'Excluida del inventario valido; motivo exacto pendiente de comprobar.'}, {'original': 'individuo 0043/img01_ind_cm0043.jpg', 'individuo': 'individuo 0043', 'fecha_exif': '2022-07-04T01:30:05', 'dia_operativo': '2022-07-03', 'sesion_candidata': 'R002', 'sha256_original': '3c52f2e30d6e151b188e4cceaa8bad3ee6d586a90c5a616b48ea5cb8333977ec', 'consultada_en_historial_40': False, 'motivo_anterior': 'Excluida del inventario valido; motivo exacto pendiente de comprobar.'}, {'original': 'individuo 0043/img02_ind_cm0043.jpg', 'individuo': 'individuo 0043', 'fecha_exif': '2022-07-04T01:30:27', 'dia_operativo': '2022-07-03', 'sesion_candidata': 'R002', 'sha256_original': 'f32c007a5b9f490daf7bc81068a3e25d9367404698f5e6db25c469fe77c9494c', 'consultada_en_historial_40': False, 'motivo_anterior': 'Excluida del inventario valido; motivo exacto pendiente de comprobar.'}, {'original': 'individuo 0150/img15_ind_cm0150.jpg', 'individuo': 'individuo 0150', 'fecha_exif': '2021-08-07T04:39:52', 'dia_operativo': '2021-08-06', 'sesion_candidata': 'R003', 'sha256_original': 'b75a6754dcc4f1f264e36a684aade118d98efb4a2553b6c69abf1004cf9ae7ae', 'consultada_en_historial_40': False, 'motivo_anterior': 'Excluida del inventario valido; motivo exacto pendiente de comprobar.'}, {'original': 'individuo 0150/img16_ind_cm0150.jpg', 'individuo': 'individuo 0150', 'fecha_exif': '2021-08-07T04:40:07', 'dia_operativo': '2021-08-06', 'sesion_candidata': 'R003', 'sha256_original': 'cd8337ee2247fe1a6c30d6fdc3b19f4db08c7720caf2dcd26228d2ec8c8995de', 'consultada_en_historial_40': False, 'motivo_anterior': 'Excluida del inventario valido; motivo exacto pendiente de comprobar.'}, {'original': 'individuo 0150/img17_ind_cm0150.jpg', 'individuo': 'individuo 0150', 'fecha_exif': '2021-08-07T04:40:11', 'dia_operativo': '2021-08-06', 'sesion_candidata': 'R003', 'sha256_original': '7f024adb5318e86b9e51f6c03dde4eb679951a51212ed733218887e4c3b597b3', 'consultada_en_historial_40': False, 'motivo_anterior': 'Excluida del inventario valido; motivo exacto pendiente de comprobar.'}, {'original': 'individuo 0150/img18_ind_cm0150.jpg', 'individuo': 'individuo 0150', 'fecha_exif': '2023-08-23T03:49:21', 'dia_operativo': '2023-08-22', 'sesion_candidata': 'R004', 'sha256_original': 'dbd771e43bbc59cdb8f090756a41a5d46502a47df51d22349e6f5ec7d9aa2bf0', 'consultada_en_historial_40': False, 'motivo_anterior': 'Excluida del inventario valido; motivo exacto pendiente de comprobar.'}, {'original': 'individuo 0390/img01_ind_cm0390.jpg', 'individuo': 'individuo 0390', 'fecha_exif': '2020-06-13T00:09:36', 'dia_operativo': '2020-06-12', 'sesion_candidata': 'R005', 'sha256_original': '92b8ae00a9a8d8b7ecb50eafe3001db6d26780ecd9e54611f667f4cec1e54852', 'consultada_en_historial_40': False, 'motivo_anterior': 'Excluida del inventario valido; motivo exacto pendiente de comprobar.'}, {'original': 'individuo 0399/img01_ind_cm0399.jpg', 'individuo': 'individuo 0399', 'fecha_exif': '2020-06-16T23:23:34', 'dia_operativo': '2020-06-16', 'sesion_candidata': 'R006', 'sha256_original': 'b4ee9854e80d854cf203a85206c1978b9cee1d808f06cd8f5a39f9789a99071b', 'consultada_en_historial_40': False, 'motivo_anterior': 'Excluida del inventario valido; motivo exacto pendiente de comprobar.'}, {'original': 'individuo 0399/img02_ind_cm0399.jpg', 'individuo': 'individuo 0399', 'fecha_exif': '2020-06-16T23:24:02', 'dia_operativo': '2020-06-16', 'sesion_candidata': 'R006', 'sha256_original': '55e93d1ae97fd6576ba8e2fef30be30dea4c26d91e8837d3822acf365c299304', 'consultada_en_historial_40': False, 'motivo_anterior': 'Excluida del inventario valido; motivo exacto pendiente de comprobar.'}, {'original': 'individuo 0402/img07_ind_cm0402.jpg', 'individuo': 'individuo 0402', 'fecha_exif': '2017-06-22T03:30:03', 'dia_operativo': '2017-06-21', 'sesion_candidata': 'R007', 'sha256_original': '7e061b9e882297339ff2cc2b8750a64e563800db5a2540c90aa05ea5cccd6272', 'consultada_en_historial_40': False, 'motivo_anterior': 'Excluida del inventario valido; motivo exacto pendiente de comprobar.'}, {'original': 'individuo 0456/img26_ind_cm0456.jpg', 'individuo': 'individuo 0456', 'fecha_exif': '2017-06-29T23:36:36', 'dia_operativo': '2017-06-29', 'sesion_candidata': 'R008', 'sha256_original': '91c2df218c28ab6e044609b489fa190c74ae7d608bdddd970c74a4e4416db6ce', 'consultada_en_historial_40': False, 'motivo_anterior': 'Excluida del inventario valido; motivo exacto pendiente de comprobar.'}, {'original': 'individuo 0456/img27_ind_cm0456.jpg', 'individuo': 'individuo 0456', 'fecha_exif': '2017-06-29T23:36:44', 'dia_operativo': '2017-06-29', 'sesion_candidata': 'R008', 'sha256_original': '13ab29d6f09428bb64a745efdb5d82d2854f629f59e757ec8e874c2f563b8e0b', 'consultada_en_historial_40': False, 'motivo_anterior': 'Excluida del inventario valido; motivo exacto pendiente de comprobar.'}, {'original': 'individuo 0555/img01_ind_cm0555.jpg', 'individuo': 'individuo 0555', 'fecha_exif': '2020-08-10T02:34:33', 'dia_operativo': '2020-08-09', 'sesion_candidata': 'R009', 'sha256_original': '4fb9fd6556478bd5a4ca171c196b2e5a05fa4032fbcd318973c11c273dfbd40d', 'consultada_en_historial_40': False, 'motivo_anterior': 'Excluida del inventario valido; motivo exacto pendiente de comprobar.'}, {'original': 'individuo 0593/img06_ind_cm0593.jpg', 'individuo': 'individuo 0593', 'fecha_exif': '2023-08-19T03:24:02', 'dia_operativo': '2023-08-18', 'sesion_candidata': 'R010', 'sha256_original': '02e2aca12a534d82dd756377db88935a4d90b53bd1470ff664ba0cf0e8c5e5cf', 'consultada_en_historial_40': False, 'motivo_anterior': 'Excluida del inventario valido; motivo exacto pendiente de comprobar.'}, {'original': 'individuo 0593/img07_ind_cm0593.jpg', 'individuo': 'individuo 0593', 'fecha_exif': '2023-08-19T03:24:08', 'dia_operativo': '2023-08-18', 'sesion_candidata': 'R010', 'sha256_original': '46b0fab2f07765d8a0a4ff9f9ac58b446aadcee1938bac93f55454922aa2300a', 'consultada_en_historial_40': False, 'motivo_anterior': 'Excluida del inventario valido; motivo exacto pendiente de comprobar.'}, {'original': 'individuo 0593/img08_ind_cm0593.jpg', 'individuo': 'individuo 0593', 'fecha_exif': '2023-08-19T03:24:15', 'dia_operativo': '2023-08-18', 'sesion_candidata': 'R010', 'sha256_original': '65a449f130fb682d9c26ce450a7abca6fde239331bacfc1977fc58ae00587028', 'consultada_en_historial_40': False, 'motivo_anterior': 'Excluida del inventario valido; motivo exacto pendiente de comprobar.'}, {'original': 'individuo 0733/img12_ind_cm0733.jpg', 'individuo': 'individuo 0733', 'fecha_exif': '2022-06-24T00:09:09', 'dia_operativo': '2022-06-23', 'sesion_candidata': 'R011', 'sha256_original': '217a9c65ce0fb21473cd78beb0d08223ebfb6c3d0dd47ca24efcfc459658ebc5', 'consultada_en_historial_40': False, 'motivo_anterior': 'Excluida del inventario valido; motivo exacto pendiente de comprobar.'}, {'original': 'individuo 0733/img13_ind_cm0733.jpg', 'individuo': 'individuo 0733', 'fecha_exif': '2022-06-24T00:11:24', 'dia_operativo': '2022-06-23', 'sesion_candidata': 'R011', 'sha256_original': '6fcd32ce9d89069a84487e98eece8b4739237b9b695369d2eb88b2817af7dc6f', 'consultada_en_historial_40': False, 'motivo_anterior': 'Excluida del inventario valido; motivo exacto pendiente de comprobar.'}, {'original': 'individuo 0742/img02_ind_cm0742.jpg', 'individuo': 'individuo 0742', 'fecha_exif': '2024-08-17T03:56:08', 'dia_operativo': '2024-08-16', 'sesion_candidata': 'R012', 'sha256_original': '8bc826f4bd89b2959c15b7b72f9653c8a448518d36a017426eb3ad50eed7d533', 'consultada_en_historial_40': False, 'motivo_anterior': 'Excluida del inventario valido; motivo exacto pendiente de comprobar.'}, {'original': 'individuo 0742/img03_ind_cm0742.jpg', 'individuo': 'individuo 0742', 'fecha_exif': '2024-08-17T03:56:12', 'dia_operativo': '2024-08-16', 'sesion_candidata': 'R012', 'sha256_original': '689f284fa4555aae73d39fc4bd27d8e144ba0d2944dc7c76201ef6ef943c30b8', 'consultada_en_historial_40': False, 'motivo_anterior': 'Excluida del inventario valido; motivo exacto pendiente de comprobar.'}, {'original': 'individuo 0742/img04_ind_cm0742.jpg', 'individuo': 'individuo 0742', 'fecha_exif': '2024-08-17T03:58:13', 'dia_operativo': '2024-08-16', 'sesion_candidata': 'R012', 'sha256_original': 'ea9decef3a8cb43b2f9c60204e631dd4e7b4ce980a2235885b744b31c0ce4122', 'consultada_en_historial_40': False, 'motivo_anterior': 'Excluida del inventario valido; motivo exacto pendiente de comprobar.'}, {'original': 'individuo 0763/img06_ind_cm0763.jpg', 'individuo': 'individuo 0763', 'fecha_exif': '2022-06-23T23:06:55', 'dia_operativo': '2022-06-23', 'sesion_candidata': 'R013', 'sha256_original': '5f2c2d9ace16be10f0cd9e2ecb62c6b1a61c509ca990b195cbb470d8a23a0e32', 'consultada_en_historial_40': False, 'motivo_anterior': 'Excluida del inventario valido; motivo exacto pendiente de comprobar.'}, {'original': 'individuo 0763/img07_ind_cm0763.jpg', 'individuo': 'individuo 0763', 'fecha_exif': '2022-06-23T23:08:10', 'dia_operativo': '2022-06-23', 'sesion_candidata': 'R013', 'sha256_original': '5c618ac9d8eea021b9a216a8c4b3300ebba1359c92da606f5c8f82c5c81648a9', 'consultada_en_historial_40': False, 'motivo_anterior': 'Excluida del inventario valido; motivo exacto pendiente de comprobar.'}, {'original': 'individuo 0763/img21_ind_cm0763.jpg', 'individuo': 'individuo 0763', 'fecha_exif': '2022-07-25T23:06:20', 'dia_operativo': '2022-07-25', 'sesion_candidata': 'R014', 'sha256_original': '1e34a5c340b9420d9ae45591f3968f33bac01c4545937623d1effd0358bb96d9', 'consultada_en_historial_40': False, 'motivo_anterior': 'Excluida del inventario valido; motivo exacto pendiente de comprobar.'}, {'original': 'individuo 0922/img08_ind_cm0922.jpg', 'individuo': 'individuo 0922', 'fecha_exif': '2023-07-30T23:09:28', 'dia_operativo': '2023-07-30', 'sesion_candidata': 'R015', 'sha256_original': 'f49f7a80b659d12772aadcd5f1c77a577bc50242ec6d54cd0e0882d0c0351a1c', 'consultada_en_historial_40': False, 'motivo_anterior': 'Excluida del inventario valido; motivo exacto pendiente de comprobar.'}, {'original': 'individuo 0989/img03_ind_cm0989.jpg', 'individuo': 'individuo 0989', 'fecha_exif': '2024-07-19T00:37:36', 'dia_operativo': '2024-07-18', 'sesion_candidata': 'R016', 'sha256_original': 'a7b594635f91e2135d41048b6be3b5b14986415b229531b689134242e8213774', 'consultada_en_historial_40': False, 'motivo_anterior': 'Excluida del inventario valido; motivo exacto pendiente de comprobar.'}, {'original': 'individuo 0989/img02_ind_cm0989.jpg', 'individuo': 'individuo 0989', 'fecha_exif': '2024-07-19T00:37:42', 'dia_operativo': '2024-07-18', 'sesion_candidata': 'R016', 'sha256_original': '80d77b9e375080235a4b02dac74565737930ac996481f72ea5872dde3b8058ea', 'consultada_en_historial_40': False, 'motivo_anterior': 'Excluida del inventario valido; motivo exacto pendiente de comprobar.'}]

def sha(p):
    h=hashlib.sha256()
    with p.open('rb') as f:
        for b in iter(lambda:f.read(1024*1024),b''):h.update(b)
    return h.hexdigest()
def atomic_json(path,data):
    temp=path.with_suffix('.json.tmp');temp.write_text(json.dumps(data,ensure_ascii=False,indent=2),encoding='utf-8');temp.replace(path)
def open_image(path):
    with Image.open(path) as im:
        im.seek(0);out=ImageOps.exif_transpose(im).convert('RGB');out.load();return out

class Review:
    def __init__(self,root,project):
        self.root=root;self.project=project;self.dataset=project/'tortugascm (1033 ind con muchas fotos)';self.folder=project/'reportes3_0/revision_28_reserva';self.folder.mkdir(parents=True,exist_ok=True);self.index=0;self.photo=None;self.image=None;self.read_error=''
        self.file=self.folder/'REVISION_28_RESERVA.json';self.records={}
        if self.file.exists():
            state=json.loads(self.file.read_text(encoding='utf-8-sig'))
            if state.get('manifest_sha256')!=self.signature():raise ValueError('La revision existente corresponde a otra lista de fotos.')
            self.records=state.get('decisiones',{})
        atomic_json(self.folder/'manifest_28.json',MANIFEST)
        root.title('CIYFI | Revisar calidad de 28 fotos');root.geometry('1080x760');root.minsize(850,580)
        shell=ttk.Frame(root,padding=10);shell.pack(fill='both',expand=True)
        ttk.Label(shell,text='Revision de calidad | 28 fotos, 16 sesiones candidatas',font=('Segoe UI',15,'bold')).pack(anchor='w')
        ttk.Label(shell,text='Revisa la cabeza y sus patrones. No confirma identidad ni convierte estas fotos en una prueba independiente.',wraplength=1000).pack(anchor='w')
        self.title=tk.StringVar();ttk.Label(shell,textvariable=self.title,wraplength=1000).pack(anchor='w',pady=5)
        foot=ttk.Frame(shell);foot.pack(side='bottom',fill='x')
        self.warning=tk.StringVar();ttk.Label(foot,textvariable=self.warning,foreground='#854d0e',wraplength=1000).pack(anchor='w')
        self.decision=tk.StringVar(value='');row=ttk.Frame(foot);row.pack(fill='x',pady=6)
        for text,value in [('Cabeza visible y patrones utiles','CABEZA_UTIL'),('Sin cabeza util / solo caparazon','NO_UTIL'),('Necesito revisar mejor','DUDOSA')]:
            ttk.Radiobutton(row,text=text,variable=self.decision,value=value).pack(side='left',padx=(0,12))
        notes=ttk.Frame(foot);notes.pack(fill='x');ttk.Label(notes,text='Observaciones:').pack(side='left');self.notes=ttk.Entry(notes);self.notes.pack(side='left',fill='x',expand=True,padx=6)
        buttons=ttk.Frame(foot);buttons.pack(fill='x',pady=6)
        ttk.Button(buttons,text='Anterior',command=lambda:self.move(-1)).pack(side='left')
        ttk.Button(buttons,text='GUARDAR Y SEGUIR',command=self.save_next).pack(side='left',padx=8)
        ttk.Button(buttons,text='Siguiente sin guardar',command=lambda:self.move(1)).pack(side='left')
        ttk.Button(buttons,text='EXPORTAR ZIP',command=self.export).pack(side='right')
        self.status=tk.StringVar();ttk.Label(foot,textvariable=self.status).pack(anchor='w')
        self.canvas=tk.Canvas(shell,bg='#172b35',height=120,highlightthickness=0);self.canvas.pack(fill='both',expand=True);self.canvas.bind('<Configure>',lambda e:self.draw())
        self.previewdir=self.folder/'vistas';self.previewdir.mkdir(exist_ok=True)
        self.index=next((i for i,r in enumerate(MANIFEST) if r['original'] not in self.records),0);self.load()
    def signature(self):return hashlib.sha256(json.dumps(MANIFEST,sort_keys=True,ensure_ascii=False).encode()).hexdigest()
    def state(self):return {'manifest_sha256':self.signature(),'fecha_exportacion':datetime.now().astimezone().isoformat(),'total_fotos':28,'sesiones_candidatas':16,'completa':len(self.records)==28,'tipo_revision':'Calidad visual de originales; no evalua coincidencias del modelo.','reserva_independiente_confirmada':False,'decisiones':self.records,'manifest':MANIFEST}
    def persist(self):atomic_json(self.file,self.state())
    def load(self):
        r=MANIFEST[self.index];self.read_error='';self.image=None;self.decision.set('');self.notes.delete(0,'end')
        self.title.set(f'Foto {self.index+1}/28 | {r["original"]} | {r["sesion_candidata"]} | {r["fecha_exif"]}')
        self.warning.set('Ya se consulto en el historial de 40 fotos. No tratar como foto nunca vista.' if r['consultada_en_historial_40'] else 'Sesion separada segun fechas. Falta comprobar calidad y antecedentes de uso.')
        p=(self.dataset/r['original']).resolve()
        try:
            if not p.is_relative_to(self.dataset.resolve()):raise ValueError('Ruta fuera del dataset.')
            if sha(p)!=r['sha256_original']:raise ValueError('El original cambio desde la auditoria. No se podra marcar como util.')
            self.image=open_image(p);preview=ImageOps.contain(self.image,(1600,1600));preview.save(self.previewdir/f'{self.index+1:02d}.jpg',quality=90)
        except Exception as e:self.read_error=str(e);self.warning.set('No se pudo comprobar/leer esta foto: '+self.read_error)
        saved=self.records.get(r['original'])
        if saved:self.decision.set(saved['decision']);self.notes.insert(0,saved['observaciones'])
        self.status.set(f'Guardadas: {len(self.records)}/28. Los originales y particiones no se modifican.');self.draw()
    def draw(self):
        self.canvas.delete('all')
        if self.image is None:return
        width=max(10,self.canvas.winfo_width());height=max(10,self.canvas.winfo_height());im=ImageOps.contain(self.image,(width,height));self.photo=ImageTk.PhotoImage(im);self.canvas.create_image(width/2,height/2,image=self.photo)
    def move(self,delta):
        self.index=max(0,min(27,self.index+delta));self.load()
    def save_next(self):
        decision=self.decision.get()
        if decision not in ('CABEZA_UTIL','NO_UTIL','DUDOSA'):return messagebox.showinfo('Decision','Selecciona una de las tres opciones.')
        if self.read_error and decision=='CABEZA_UTIL':return messagebox.showerror('Foto','No se puede marcar como util una foto sin lectura o hash validos.')
        r=MANIFEST[self.index];self.records[r['original']]={'decision':decision,'observaciones':self.notes.get().strip(),'error_lectura':self.read_error,'fecha_revision':datetime.now().astimezone().isoformat()}
        try:self.persist()
        except Exception as e:return messagebox.showerror('Guardado','No se pudo guardar; no se avanzo. '+str(e))
        if self.index<27:self.move(1)
        else:self.status.set(f'Guardadas {len(self.records)}/28. Pulsa EXPORTAR ZIP para compartir la revision.')
    def export(self):
        try:
            self.persist();archive=self.folder/'REVISION_28_PARA_COMPARTIR.zip';temp=self.folder/'REVISION_28_PARA_COMPARTIR.zip.tmp'
            with zipfile.ZipFile(temp,'w',zipfile.ZIP_DEFLATED) as z:
                z.write(self.file,self.file.name);z.write(self.folder/'manifest_28.json','manifest_28.json')
                for p in sorted(self.previewdir.glob('*.jpg')):z.write(p,'vistas/'+p.name)
            temp.replace(archive);print('ZIP PARA COMPARTIR: '+str(archive),flush=True)
            messagebox.showinfo('Exportado',f'Guardadas {len(self.records)}/28.\nZIP: {archive}')
            if hasattr(os,'startfile'):os.startfile(str(self.folder))
        except Exception as e:messagebox.showerror('Exportacion',str(e))
def main():
    project=Path(sys.argv[1]).resolve();root=tk.Tk()
    try:Review(root,project)
    except Exception as e:messagebox.showerror('CIYFI',str(e));root.destroy();raise
    root.mainloop()
if __name__=='__main__':main()

'@
[System.IO.File]::WriteAllText($programa, $codigo, (New-Object System.Text.UTF8Encoding($false)))
& $PythonExe $programa $Proyecto
if ($LASTEXITCODE -ne 0) { throw 'La revision no se completo. Comparte el error de la terminal.' }
