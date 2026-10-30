param(
 [string]$Proyecto = 'C:\Users\cancu\Pictures\PROYECTO TORTUGAS\zproyecto3_0',
 [string]$Salida = 'C:\Users\cancu\Pictures\PROYECTO TORTUGAS\zproyecto3_0\recortes3_0\ciyfi_20261004_001459_146400'
)
$ErrorActionPreference = 'Stop'
$python = Join-Path $Proyecto '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { throw "No se encontro Python: $python" }
$env:PYTHONIOENCODING = 'utf-8'
@'
import csv, hashlib, json, math, os, sys, zipfile
from collections import Counter
from datetime import datetime
from pathlib import Path
import tkinter as tk
from tkinter import ttk, messagebox
from PIL import Image, ImageOps, ImageTk, ImageDraw


def imagen(path):
    with Image.open(path) as f:
        f.seek(0)
        out=ImageOps.exif_transpose(f).convert('RGB'); out.load(); return out


class Registro:
    def __init__(self,salida):
        self.salida=Path(salida); manifest=self.salida/'manifest_recortes.csv'
        self.rows=list(csv.DictReader(manifest.open(encoding='utf-8-sig',newline='')))
        self.sha=hashlib.sha256(manifest.read_bytes()).hexdigest()
        self.dest=self.salida/'revision_manual'; self.dest.mkdir(exist_ok=True)
        self.path=self.dest/'decisiones.json'
        self.dec={}
        if self.path.exists():
            d=json.loads(self.path.read_text(encoding='utf-8'))
            if d['sha256_manifest']!=self.sha: raise ValueError('El manifiesto cambio; no se mezclaran decisiones.')
            self.dec=d['decisiones']
        # Exclusión solicitada del falso recorte de caparazón. No elimina archivos ni individuos.
        r=next((r for r in self.rows if int(r['numero'])==3453 and r['individuo']=='individuo 0620'),None)
        if r and r['original'] not in self.dec:
            self.dec[r['original']]={'decision':'EXCLUIR','nota':'Caso 03453: caparazon en lugar de cabeza; exclusion solicitada.',
                                     'fecha':datetime.now().isoformat(timespec='seconds')}
            self.guardar()
    def guardar(self):
        tmp=self.path.with_suffix('.tmp')
        tmp.write_text(json.dumps({'sha256_manifest':self.sha,'decisiones':self.dec},ensure_ascii=False,indent=2),encoding='utf-8')
        tmp.replace(self.path)
    def decidir(self,row,decision,nota=''):
        if decision=='ACEPTAR' and (not row.get('recorte') or not (self.salida/row['recorte']).is_file()):
            raise ValueError('No existe un recorte para aceptar. Marca CORREGIR o EXCLUIR.')
        old=self.dec.get(row['original'])
        self.dec[row['original']]={'decision':decision,'nota':nota,'fecha':datetime.now().isoformat(timespec='seconds')}
        try: self.guardar()
        except Exception:
            if old is None: self.dec.pop(row['original'],None)
            else: self.dec[row['original']]=old
            raise
    def exportar(self):
        fields=list(self.rows[0])+['decision_manual','nota_manual','fecha_revision']
        enriched=[]
        for r in self.rows:
            d=self.dec.get(r['original'],{})
            enriched.append(dict(r,decision_manual=d.get('decision','PENDIENTE'),
                                 nota_manual=d.get('nota',''),fecha_revision=d.get('fecha','')))
        for name,rows in [('revision_completa.csv',enriched),('aceptados.csv',[r for r in enriched if r['decision_manual']=='ACEPTAR']),
                          ('por_corregir.csv',[r for r in enriched if r['decision_manual']=='CORREGIR']),
                          ('excluidos.csv',[r for r in enriched if r['decision_manual']=='EXCLUIR'])]:
            p=self.dest/name; tmp=p.with_suffix('.tmp')
            with tmp.open('w',encoding='utf-8-sig',newline='') as f:
                w=csv.DictWriter(f,fieldnames=fields);w.writeheader();w.writerows(rows)
            tmp.replace(p)
        counts=dict(Counter(r['decision_manual'] for r in enriched))
        (self.dest/'resumen.json').write_text(json.dumps(counts,indent=2),encoding='utf-8')
        out=self.dest/'REVISION_MANUAL_PARA_COMPARTIR.zip'
        with zipfile.ZipFile(out,'w',zipfile.ZIP_DEFLATED) as z:
            for p in [self.path,self.dest/'resumen.json']+sorted(self.dest.glob('*.csv')): z.write(p,p.name)
        return out


class Visor:
    def __init__(self,root,salida):
        self.root=root; self.reg=Registro(salida); self.salida=self.reg.salida
        self.dataset=Path(json.loads((self.salida/'configuracion.json').read_text(encoding='utf-8'))['dataset'])
        order={'BAJA_CONFIANZA':0,'VARIAS_CAJAS':1,'SIN_DETECCION':2,'ERROR':3}
        incidencias=sorted([r for r in self.reg.rows if r['estado'] in order],key=lambda r:(order[r['estado']],int(r['numero'])))
        muestra=list(csv.DictReader((self.salida/'MUESTRA_PARA_REVISAR.csv').open(encoding='utf-8-sig',newline='')))
        self.grupos={'Incidencias':incidencias,'Muestra de candidatos':muestra}
        root.title('CiyFi - revision de recortes'); root.geometry('1120x790'); root.minsize(850,680)
        top=ttk.Frame(root);top.pack(fill='x',padx=10,pady=8)
        ttk.Label(top,text='Grupo:').pack(side='left')
        self.tipo=tk.StringVar(value='Incidencias')
        combo=ttk.Combobox(top,textvariable=self.tipo,values=list(self.grupos),state='readonly',width=25);combo.pack(side='left',padx=5)
        combo.bind('<<ComboboxSelected>>',lambda e:self.configurar())
        ttk.Label(top,text='Lote:').pack(side='left')
        self.lote=tk.StringVar();self.combo=ttk.Combobox(top,textvariable=self.lote,state='readonly',width=7)
        self.combo.pack(side='left',padx=5);self.combo.bind('<<ComboboxSelected>>',lambda e:self.abrir_lote())
        ttk.Button(top,text='Exportar avance ZIP',command=self.exportar).pack(side='right')
        self.info=ttk.Label(root,wraplength=1080);self.info.pack(fill='x',padx=10)
        self.canvas=tk.Canvas(root,bg='#252525',height=470,highlightthickness=0);self.canvas.pack(fill='both',expand=True,padx=10,pady=8)
        self.estado=ttk.Label(root);self.estado.pack(fill='x',padx=10)
        ttk.Label(root,text='Aceptar: cabeza util. Corregir: caja incorrecta recuperable. Excluir: sin informacion util.').pack(pady=4)
        notes=ttk.Frame(root);notes.pack(fill='x',padx=10)
        ttk.Label(notes,text='Nota opcional:').pack(side='left');self.nota=tk.StringVar()
        ttk.Entry(notes,textvariable=self.nota).pack(side='left',fill='x',expand=True,padx=8)
        buttons=ttk.Frame(root);buttons.pack(pady=10)
        self.aceptar=ttk.Button(buttons,text='ACEPTAR [A]',command=lambda:self.decidir('ACEPTAR'));self.aceptar.pack(side='left',padx=5)
        ttk.Button(buttons,text='CORREGIR [C]',command=lambda:self.decidir('CORREGIR')).pack(side='left',padx=5)
        ttk.Button(buttons,text='EXCLUIR [E]',command=lambda:self.decidir('EXCLUIR')).pack(side='left',padx=5)
        ttk.Button(buttons,text='Dejar pendiente / siguiente',command=self.siguiente).pack(side='left',padx=5)
        nav=ttk.Frame(root);nav.pack(pady=(0,8))
        ttk.Button(nav,text='Anterior',command=self.anterior).pack(side='left',padx=8)
        ttk.Button(nav,text='Abrir foto original para ampliar',command=self.original).pack(side='left',padx=8)
        ttk.Label(root,text='Las decisiones se guardan al pulsar un boton. CORREGIR solo marca pendiente de correccion.').pack(pady=(0,8))
        for key,decision in [('a','ACEPTAR'),('c','CORREGIR'),('e','EXCLUIR')]:
            root.bind(key,lambda e,d=decision:self.decidir(d) if not isinstance(root.focus_get(),ttk.Entry) else None)
        root.protocol('WM_DELETE_WINDOW',self.cerrar)
        self.configurar()
    def configurar(self):
        self.queue=self.grupos[self.tipo.get()]
        if not self.queue: raise ValueError('No hay imagenes en este grupo.')
        self.combo['values']=[str(i+1) for i in range(math.ceil(len(self.queue)/100))]
        pending=next((i for i,r in enumerate(self.queue) if r['original'] not in self.reg.dec),0)
        self.lote.set(str(pending//100+1));self.abrir_lote()
    def abrir_lote(self):
        self.inicio=(int(self.lote.get())-1)*100;self.fin=min(self.inicio+100,len(self.queue))
        self.index=next((i for i in range(self.inicio,self.fin) if self.queue[i]['original'] not in self.reg.dec),self.inicio)
        self.mostrar()
    def mostrar(self):
        r=self.queue[self.index];d=self.reg.dec.get(r['original'],{})
        done=sum(r['original'] in self.reg.dec for r in self.queue[self.inicio:self.fin])
        self.info['text']=f"Lote {self.lote.get()} | {self.index-self.inicio+1}/{self.fin-self.inicio} | Revisados {done}/{self.fin-self.inicio}\nFoto {int(r['numero']):05d} | {r['individuo']} | {r['estado']} | Confianza {r.get('confianza') or '-'}"
        self.estado['text']='Decision guardada: '+d.get('decision','PENDIENTE')
        self.nota.set(d.get('nota',''));self.canvas.delete('all');self.visible=False
        try:
            if r.get('panel') and (self.salida/r['panel']).is_file(): im=imagen(self.salida/r['panel'])
            else:
                im=Image.new('RGB',(960,460),'#252525');draw=ImageDraw.Draw(im)
                for x,path,label in [(0,self.dataset/r['original'],'ORIGINAL'),(480,self.salida/r['recorte'] if r.get('recorte') else None,'RECORTE')]:
                    draw.text((x+8,8),label,fill='white')
                    if path and path.is_file():
                        pic=ImageOps.contain(imagen(path),(470,410));im.paste(pic,(x+(480-pic.width)//2,35+(410-pic.height)//2))
            self.root.update_idletasks()
            im=ImageOps.contain(im,(max(820,self.canvas.winfo_width()),max(360,self.canvas.winfo_height())))
            self.photo=ImageTk.PhotoImage(im);self.canvas.create_image(self.canvas.winfo_width()/2,self.canvas.winfo_height()/2,image=self.photo)
            self.visible=True
        except Exception as e: self.canvas.create_text(420,170,text='No se pudo mostrar: '+str(e),fill='white',width=750)
        allowed=self.visible and r.get('recorte') and (self.salida/r['recorte']).is_file()
        self.aceptar['state']='normal' if allowed else 'disabled'
    def decidir(self,decision):
        if decision=='ACEPTAR' and self.aceptar['state']=='disabled': return
        try: self.reg.decidir(self.queue[self.index],decision,self.nota.get())
        except Exception as e: messagebox.showerror('No se guardo la decision',str(e));return
        self.siguiente()
    def siguiente(self):
        if self.index+1<self.fin: self.index+=1;self.mostrar()
        else:
            self.mostrar();messagebox.showinfo('Fin del lote','Llegaste al final de este lote. Selecciona el siguiente arriba.\nPuedes cerrar y continuar despues; tus decisiones ya estan guardadas.')
    def anterior(self): self.index=max(self.inicio,self.index-1);self.mostrar()
    def original(self):
        try: os.startfile(str(self.dataset/self.queue[self.index]['original']))
        except Exception as e: messagebox.showerror('No se pudo abrir',str(e))
    def exportar(self):
        try:
            out=self.reg.exportar();print('ZIP PARA COMPARTIR:',out,flush=True)
            messagebox.showinfo('Avance exportado',str(out));return True
        except Exception as e:
            messagebox.showerror('No se pudo exportar','Cierra los CSV si estan abiertos en Excel y vuelve a intentar.\n'+str(e));return False
    def cerrar(self):
        if self.exportar(): self.root.destroy()


def main():
    root=tk.Tk()
    try: Visor(root,sys.argv[1])
    except Exception as e: messagebox.showerror('CiyFi',str(e));root.destroy();raise
    root.mainloop()

if __name__=='__main__': main()
'@ | & $python - $Salida
if ($LASTEXITCODE -ne 0) { throw 'No se pudo abrir el revisor. Comparte el error de la terminal.' }
