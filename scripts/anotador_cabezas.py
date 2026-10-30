import csv
import json
import sys
import zipfile
from datetime import datetime
from pathlib import Path
import tkinter as tk
from tkinter import messagebox, ttk
from PIL import Image, ImageDraw, ImageOps, ImageTk


def escribir_json(ruta, contenido):
    temporal = ruta.with_suffix('.tmp')
    temporal.write_text(json.dumps(contenido, ensure_ascii=False, indent=2), encoding='utf-8')
    temporal.replace(ruta)


def preparar(proyecto):
    muestra = proyecto / 'reportes3_0/comparacion_detectores_20261003_172337_042170/muestra.csv'
    dataset = proyecto / 'tortugascm (1033 ind con muchas fotos)'
    if not muestra.is_file():
        raise FileNotFoundError(f'No se encuentra: {muestra}')
    with muestra.open(encoding='utf-8-sig', newline='') as f:
        seleccion = list(csv.DictReader(f))
    base = proyecto / 'anotaciones3_0/piloto40'
    manifest = base / 'manifest.json'
    if manifest.exists():
        registros = json.loads(manifest.read_text(encoding='utf-8'))
        if [r['ruta_original'] for r in registros] != [r['ruta_relativa'] for r in seleccion]:
            raise RuntimeError('La muestra cambio. Conserva esta carpeta y prepara otro piloto.')
        for r in registros:
            if not (base / 'images' / r['archivo']).is_file():
                raise FileNotFoundError(f"Falta la copia: {r['archivo']}")
        return base, registros
    (base / 'images').mkdir(parents=True, exist_ok=True)
    registros = []
    for n, fila in enumerate(seleccion, 1):
        ruta = dataset / fila['ruta_relativa']
        with Image.open(ruta) as im:
            im.seek(0)
            im.load()
            orientada = ImageOps.exif_transpose(im)
            try:
                rgb = orientada.convert('RGB')
            finally:
                if orientada is not im:
                    orientada.close()
        ancho, alto = rgb.size
        rgb.thumbnail((1600, 1600), Image.Resampling.LANCZOS)
        archivo = f'{n:03d}.jpg'
        rgb.save(base / 'images' / archivo, quality=95)
        registros.append({
            'numero': str(n), 'individuo': fila['individuo'],
            'ruta_original': fila['ruta_relativa'], 'archivo': archivo,
            'ancho_original': ancho, 'alto_original': alto,
            'ancho_copia': rgb.width, 'alto_copia': rgb.height,
        })
        rgb.close()
        print(f'Preparando copia {n}/{len(seleccion)}', flush=True)
    escribir_json(manifest, registros)
    return base, registros


def limites_caja(caja, ancho, alto):
    x1, y1, x2, y2 = caja
    return [
        max(0, min(ancho, min(x1, x2))),
        max(0, min(alto, min(y1, y2))),
        max(0, min(ancho, max(x1, x2))),
        max(0, min(alto, max(y1, y2))),
    ]


def exportar(base, registros, estado):
    salida = base / 'exportaciones' / datetime.now().strftime('%Y%m%d_%H%M%S_%f')
    salida.mkdir(parents=True)
    for carpeta in ('images', 'labels', 'revision_visual'):
        (salida / carpeta).mkdir()
    filas = []
    for r in registros:
        fila = {**r, 'estado': 'PENDIENTE', 'cabeza': '', 'escamas': '',
                'x1': '', 'y1': '', 'x2': '', 'y2': ''}
        a = estado.get(r['numero'])
        if a:
            w, h = r['ancho_copia'], r['alto_copia']
            x1, y1, x2, y2 = limites_caja(a['caja'], w, h)
            if x2 <= x1 or y2 <= y1:
                raise ValueError(f"Caja invalida: foto {r['numero']}")
            fila.update(estado='ANOTADA', cabeza=a['cabeza'], escamas=a['escamas'],
                        x1=x1, y1=y1, x2=x2, y2=y2)
            etiqueta = f'0 {(x1+x2)/(2*w):.8f} {(y1+y2)/(2*h):.8f} {(x2-x1)/w:.8f} {(y2-y1)/h:.8f}\n'
            (salida / 'labels' / Path(r['archivo']).with_suffix('.txt')).write_text(etiqueta, encoding='utf-8')
            (salida / 'images' / r['archivo']).write_bytes((base / 'images' / r['archivo']).read_bytes())
            with Image.open(base / 'images' / r['archivo']) as im:
                vista = im.convert('RGB')
            ImageDraw.Draw(vista).rectangle((x1, y1, x2, y2), outline='lime', width=4)
            vista.save(salida / 'revision_visual' / r['archivo'], quality=90)
            vista.close()
        filas.append(fila)
    with (salida / 'revision.csv').open('w', encoding='utf-8-sig', newline='') as f:
        escritor = csv.DictWriter(f, fieldnames=list(filas[0]))
        escritor.writeheader()
        escritor.writerows(filas)
    escribir_json(salida / 'anotaciones.json', estado)
    escribir_json(salida / 'manifest.json', registros)
    total = sum(f['estado'] == 'ANOTADA' for f in filas)
    (salida / 'LEEME.txt').write_text(
        f'Fotos anotadas: {total}/{len(registros)}\n'
        'Clase YOLO 0: cabeza_tortuga. Coordenadas relativas a las copias orientadas.\n'
        'Las copias tienen un lado maximo de 1600 px; los originales no cambiaron.\n'
        'Las fotos pendientes no tienen etiquetas ni se incluyen como negativos.\n'
        'No hay particiones train/val/test; este paquete es para revision.\n', encoding='utf-8')
    ruta_zip = salida.with_suffix('.zip')
    with zipfile.ZipFile(ruta_zip, 'w', compression=zipfile.ZIP_DEFLATED) as z:
        for p in sorted(salida.rglob('*')):
            if p.is_file():
                z.write(p, arcname=str(p.relative_to(salida)))
    return ruta_zip, total


class Anotador:
    def __init__(self, root, base, registros):
        self.root, self.base, self.registros = root, base, registros
        self.ruta_estado = base / 'anotaciones.json'
        self.estado = json.loads(self.ruta_estado.read_text(encoding='utf-8')) if self.ruta_estado.exists() else {}
        self.indice = next((i for i, r in enumerate(registros) if r['numero'] not in self.estado), 0)
        self.caja, self.inicio, self.imagen = None, None, None
        self.dirty, self.cargando = False, False
        root.title('Tortugas 3.0 - Anotacion manual de cabezas')
        root.geometry('1100x850')
        self.titulo = tk.StringVar()
        ttk.Label(root, textvariable=self.titulo, font=('Segoe UI', 12, 'bold')).pack(pady=5)
        ttk.Label(root, text='Arrastra del extremo superior izquierdo al inferior derecho de la cabeza.').pack()
        ttk.Label(root, text='Incluye hocico y escamas; evita cuello, caparazon y aletas. Marca solo lo visible si esta parcial.').pack()
        self.canvas = tk.Canvas(root, background='#333333', highlightthickness=0)
        self.canvas.pack(fill='both', expand=True, padx=8, pady=6)
        self.canvas.bind('<Configure>', lambda event: self.dibujar())
        self.canvas.bind('<ButtonPress-1>', self.presionar)
        self.canvas.bind('<B1-Motion>', self.arrastrar)
        self.canvas.bind('<ButtonRelease-1>', self.soltar)
        opciones = ttk.Frame(root)
        opciones.pack(pady=4)
        self.cabeza = tk.StringVar(value='Seleccionar')
        self.escamas = tk.StringVar(value='Seleccionar')
        for label, variable, valores in [
            ('Cabeza:', self.cabeza, ['Seleccionar', 'Completa', 'Parcial']),
            ('Escamas:', self.escamas, ['Seleccionar', 'Distinguibles', 'Dudosas', 'No distinguibles'])
        ]:
            ttk.Label(opciones, text=label).pack(side='left', padx=4)
            ttk.Combobox(opciones, textvariable=variable, values=valores, state='readonly', width=20).pack(side='left', padx=4)
            variable.trace_add('write', self.cambio)
        botones = ttk.Frame(root)
        botones.pack(pady=5)
        for texto, accion in [
            ('Anterior', lambda: self.navegar(-1)), ('Siguiente', lambda: self.navegar(1)),
            ('Borrar caja', self.borrar), ('Guardar y avanzar', self.guardar_avanzar),
            ('Exportar ZIP', self.exportar)
        ]:
            ttk.Button(botones, text=texto, command=accion).pack(side='left', padx=4)
        ttk.Label(root, text='Siguiente deja pendiente si no guardas. Exportar ZIP incluye solo las fotos anotadas.').pack(pady=3)
        root.protocol('WM_DELETE_WINDOW', self.cerrar)
        self.mostrar()

    def cambio(self, *args):
        if not self.cargando:
            self.dirty = True

    def mostrar(self):
        if self.imagen:
            self.imagen.close()
        r = self.registros[self.indice]
        with Image.open(self.base / 'images' / r['archivo']) as im:
            self.imagen = im.convert('RGB')
        a = self.estado.get(r['numero'], {})
        self.caja = list(a['caja']) if a else None
        self.cargando = True
        self.cabeza.set(a.get('cabeza', 'Seleccionar'))
        self.escamas.set(a.get('escamas', 'Seleccionar'))
        self.cargando = False
        self.dirty = False
        self.titulo.set(f"Foto {self.indice+1}/{len(self.registros)} | {r['individuo']} | Guardadas: {len(self.estado)}/{len(self.registros)}")
        self.dibujar()

    def dibujar(self):
        if self.imagen is None:
            return
        cw, ch = max(10, self.canvas.winfo_width()), max(10, self.canvas.winfo_height())
        w, h = self.imagen.size
        self.escala = min(cw/w, ch/h)
        dw, dh = max(1, round(w*self.escala)), max(1, round(h*self.escala))
        self.ox, self.oy = (cw-dw)/2, (ch-dh)/2
        # Exact scales after rounding, so label coordinates match the copy.
        self.sx, self.sy = dw/w, dh/h
        self.foto = ImageTk.PhotoImage(self.imagen.resize((dw, dh), Image.Resampling.LANCZOS))
        self.canvas.delete('all')
        self.canvas.create_image(self.ox, self.oy, image=self.foto, anchor='nw')
        self.rectangulo()

    def rectangulo(self):
        self.canvas.delete('caja')
        if self.caja:
            x1,y1,x2,y2 = self.caja
            self.canvas.create_rectangle(self.ox+x1*self.sx, self.oy+y1*self.sy,
                self.ox+x2*self.sx, self.oy+y2*self.sy, outline='#00ff00', width=3, tags='caja')

    def punto(self, event):
        w,h = self.imagen.size
        return max(0,min(w,(event.x-self.ox)/self.sx)), max(0,min(h,(event.y-self.oy)/self.sy))

    def presionar(self, event):
        w,h = self.imagen.size
        if not (self.ox <= event.x <= self.ox+w*self.sx and self.oy <= event.y <= self.oy+h*self.sy):
            return
        self.inicio = self.punto(event)
        self.caja = [*self.inicio, *self.inicio]
        self.dirty = True
        self.rectangulo()

    def arrastrar(self, event):
        if self.inicio is not None:
            self.caja = limites_caja([*self.inicio, *self.punto(event)], *self.imagen.size)
            self.rectangulo()

    def soltar(self, event):
        self.arrastrar(event)
        self.inicio = None

    def borrar(self):
        self.caja = None
        self.dirty = True
        self.rectangulo()

    def guardar(self):
        if not self.caja or self.caja[2]-self.caja[0] < 3 or self.caja[3]-self.caja[1] < 3:
            messagebox.showwarning('Falta caja', 'Dibuja una caja valida alrededor de la cabeza.')
            return False
        if 'Seleccionar' in (self.cabeza.get(), self.escamas.get()):
            messagebox.showwarning('Falta revision', 'Selecciona cabeza Completa/Parcial y visibilidad de las escamas.')
            return False
        clave = self.registros[self.indice]['numero']
        anterior = self.estado.get(clave)
        self.estado[clave] = {'caja': self.caja[:], 'cabeza': self.cabeza.get(),
                             'escamas': self.escamas.get(), 'fecha': datetime.now().isoformat(timespec='seconds')}
        try:
            escribir_json(self.ruta_estado, self.estado)
        except Exception as error:
            if anterior is None:
                self.estado.pop(clave, None)
            else:
                self.estado[clave] = anterior
            messagebox.showerror('Error al guardar', str(error))
            return False
        self.dirty = False
        return True

    def resolver_cambios(self):
        if not self.dirty:
            return True
        respuesta = messagebox.askyesnocancel('Cambios sin guardar', '¿Guardar los cambios de esta foto?\nNo: descarta los cambios actuales. Cancelar: sigue aqui.')
        if respuesta is None:
            return False
        if respuesta:
            return self.guardar()
        self.dirty = False
        return True

    def navegar(self, paso):
        destino = self.indice + paso
        if 0 <= destino < len(self.registros) and self.resolver_cambios():
            self.indice = destino
            self.mostrar()

    def guardar_avanzar(self):
        if self.guardar():
            if self.indice < len(self.registros)-1:
                self.indice += 1
            else:
                messagebox.showinfo('Ultima foto', 'Anotacion guardada. Puedes revisar pendientes o exportar el ZIP.')
            self.mostrar()

    def exportar(self):
        if not self.resolver_cambios():
            return
        self.mostrar()
        if not self.estado:
            messagebox.showwarning('Sin anotaciones', 'Guarda al menos una foto antes de exportar.')
            return
        try:
            ruta, total = exportar(self.base, self.registros, self.estado)
            print(f'ZIP PARA COMPARTIR: {ruta}', flush=True)
            messagebox.showinfo('Exportacion terminada', f'Fotos anotadas: {total}/{len(self.registros)}\n\nZIP:\n{ruta}\n\nLa ruta tambien aparece en PowerShell.')
        except Exception as error:
            messagebox.showerror('Error al exportar', str(error))

    def cerrar(self):
        if self.resolver_cambios():
            self.imagen.close()
            self.root.destroy()


if __name__ == '__main__':
    base, registros = preparar(Path(sys.argv[1]).resolve())
    if not registros:
        raise RuntimeError('La muestra esta vacia.')
    print(f'Anotaciones: {base}\nAbriendo ventana local...', flush=True)
    root = tk.Tk()
    app = Anotador(root, base, registros)
    root.mainloop()

