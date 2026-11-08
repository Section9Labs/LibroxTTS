#!/usr/bin/env python3
"""Render all default language voices with the same native SDK probe."""
import argparse,json,pathlib,subprocess,time
TEXTS={
'en':'The library was quiet. Beyond the window, rain drifted through the evening light. She closed the book and listened.',
'es':'La biblioteca estaba en silencio. Al otro lado de la ventana, la lluvia caía suavemente. Cerró el libro y se puso a escuchar.',
'fr':'La bibliothèque était silencieuse. Derrière la fenêtre, la pluie tombait doucement. Elle ferma le livre et écouta.',
'de':'In der Bibliothek war es still. Vor dem Fenster fiel leise der Regen. Sie schloss das Buch und lauschte.',
'it':'La biblioteca era silenziosa. Oltre la finestra, la pioggia cadeva dolcemente. Chiuse il libro e si mise ad ascoltare.',
'pt':'A biblioteca estava silenciosa. Do outro lado da janela, a chuva caía suavemente. Ela fechou o livro e ficou a ouvir.',
'nl':'Het was stil in de bibliotheek. Buiten het raam viel de regen zachtjes. Ze sloot het boek en luisterde.'}
VOICES=dict(en='alba',es='lola',fr='estelle',de='alba',it='giovanni',pt='alba',nl='daan')
def main():
    p=argparse.ArgumentParser();p.add_argument('--probe',required=True);p.add_argument('--assets',required=True);p.add_argument('--output',type=pathlib.Path,required=True);a=p.parse_args();a.output.mkdir(parents=True,exist_ok=True)
    report=[]
    for code,text in TEXTS.items():
     command=[a.probe,a.assets,f'pocket-{VOICES[code]}-{code}-v1',str(a.output/f'{code}.wav'),text]
     result=subprocess.run(command,capture_output=True,text=True)
     row=dict(language=code,voice=VOICES[code],text=text,exitCode=result.returncode,output=result.stdout,errors=result.stderr)
     report.append(row);print(json.dumps(row,ensure_ascii=False),flush=True)
    (a.output/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    if any(row['exitCode'] for row in report):raise SystemExit(1)

if __name__ == "__main__": main()
