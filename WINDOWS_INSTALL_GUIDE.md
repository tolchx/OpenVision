# Guía de Instalación de OpenVision en Windows (con Sideloadly)

Esta guía explica cómo compilar e instalar OpenVision en tu iPhone desde Windows,
usando GitHub Actions para compilar y Sideloadly para instalar.

---

## Requisitos Previos

- **iPhone** con iOS 16+ en modo Developer
- **Ray-Ban Meta Gen 2** (emparejados via Bluetooth con tu iPhone)
- **Cuenta GitHub** (gratuita)
- **Cuenta Apple ID** (para firmar con Sideloadly)
- **Sideloadly** instalado en Windows → https://sideloadly.io
- **Gemini API Key** → https://aistudio.google.com/app/apikey
- **Cuenta Meta Developer** → https://developer.meta.com

---

## Paso 1: Obtener Credenciales de Meta Developer

Necesitas estas credenciales para que la app se comunique con tus Ray-Ban Meta.

1. Ve a [developer.meta.com](https://developer.meta.com)
2. Inicia sesión con tu cuenta de Meta/Facebook
3. Crea una nueva app (tipo: "Consumer")
4. En el dashboard de la app:
   - Haz clic en **"Add Product"**
   - Busca y añade **"Meta Wearables"**
5. Copia estos valores:
   - **App ID**: Número largo en la parte superior del dashboard (ej: `1234567890`)
   - **Client Token**: Ve a **Settings → Advanced** y copia el Client Token
6. El Client Token debe tener el formato: `AR|TU_APP_ID|TU_CLIENT_TOKEN`
   - Ejemplo: `AR|1234567890|abcdef123456`

---

## Paso 2: Fork del Repositorio en GitHub

1. Ve a [github.com/rayl15/OpenVision](https://github.com/rayl15/OpenVision)
2. Haz clic en **"Fork"** (esquina superior derecha)
3. Esto crea una copia en tu cuenta: `github.com/TU_USUARIO/OpenVision`

---

## Paso 3: Subir el Workflow de Compilación

El archivo `.github/workflows/build-ipa.yml` ya está creado en tu repo local.
Necesitas subirlo a tu fork:

### Opción A: Desde la terminal (Git)
```bash
cd C:\Users\tolch\Documents\AI_Code\OpenVision
git remote set-url origin https://github.com/TU_USUARIO/OpenVision.git
git add .github/workflows/build-ipa.yml
git commit -m "Add GitHub Actions workflow for IPA build"
git push origin main
```

### Opción B: Desde GitHub Web
1. Ve a tu fork en GitHub
2. Navega a `.github/workflows/`
3. Crea un nuevo archivo `build-ipa.yml`
4. Copia el contenido del archivo local `.github/workflows/build-ipa.yml`
5. Haz commit

---

## Paso 4: Configurar Secrets en GitHub

En tu fork de GitHub:

1. Ve a **Settings → Secrets and variables → Actions**
2. Crea estos **Repository secrets**:

| Secret Name     | Valor                                          |
|-----------------|------------------------------------------------|
| `META_APP_ID`   | Tu App ID de Meta (ej: `1234567890`)           |
| `CLIENT_TOKEN`  | Token completo (ej: `AR\|1234567890\|abcdef`)  |

> **Nota:** La Gemini API Key NO va aquí. Se configura dentro de la app después de instalarla.

---

## Paso 5: Ejecutar el Workflow (Compilar la IPA)

1. En tu fork, ve a la pestaña **"Actions"**
2. Si es la primera vez, haz clic en **"I understand my workflows, go ahead and enable them"**
3. En el panel izquierdo, selecciona **"Build OpenVision IPA"**
4. Haz clic en **"Run workflow"**
5. Opcionalmente cambia el Bundle Identifier (ej: `com.tunombre.openvision`)
6. Haz clic en el botón verde **"Run workflow"**
7. Espera ~10-15 minutos a que termine la compilación
8. Una vez completado (check verde ✅), haz clic en el workflow run
9. En la sección **"Artifacts"**, descarga **"OpenVision-IPA"**
10. Descomprime el ZIP descargado para obtener `OpenVision.ipa`

---

## Paso 6: Instalar con Sideloadly

1. Descarga e instala **Sideloadly** desde https://sideloadly.io
2. Conecta tu iPhone al PC por cable USB
3. Abre Sideloadly
4. En el campo de Apple ID, ingresa tu Apple ID
5. Arrastra el archivo `OpenVision.ipa` a Sideloadly (o haz clic en el icono de IPA)
6. Haz clic en **"Start"**
7. Ingresa la contraseña de tu Apple ID cuando se te pida
8. Espera a que termine la instalación

### Si usas Apple ID gratuito:
- La app expira cada **7 días** y deberás reinstalar
- Máximo 3 apps sideloaded simultáneamente
- Para evitar esto, considera Apple Developer Program ($99/año)

### Confiar en el desarrollador en iPhone:
1. Ve a **Ajustes → General → Gestión de dispositivos y VPN**
2. Toca tu Apple ID/perfil de desarrollador
3. Toca **"Confiar"**

---

## Paso 7: Configurar la App

Una vez instalada y abierta en tu iPhone:

### Configurar Gemini (tu AI backend):
1. Abre OpenVision
2. Ve a **Settings → AI Backend**
3. Selecciona **"Gemini Live"**
4. Toca **"Gemini Settings"**
5. Pega tu **Gemini API Key**

### Registrar las Glasses:
1. Asegúrate de que tus Ray-Ban Meta están emparejadas por Bluetooth
2. Ve a **Settings → Glasses**
3. Toca **"Register with Meta AI"**
4. Sigue el flujo de autenticación en la app Meta AI
5. Regresa a OpenVision

---

## Paso 8: Usar OpenVision

### Modo Gemini Live (con visión):
```
Tú: "Ok Vision, start video streaming"  → Activa cámara de las glasses (1fps)
Tú: "What am I looking at?"             → Gemini ve y responde
Tú: "Stop video"                        → Detiene el streaming
```

### Comandos de voz:
- **"Ok Vision"** → Activa la escucha
- **"Ok Vision stop"** → Detiene al AI mientras habla
- **"Take a photo"** → Captura foto desde las glasses

---

## Troubleshooting

### El workflow falla en GitHub Actions
- Verifica que los secrets estén configurados correctamente
- Revisa los logs del workflow para errores específicos
- Asegúrate de que el fork está actualizado con el repo original

### Sideloadly no instala la IPA
- Asegúrate de tener iTunes instalado en Windows
- Verifica que el iPhone está desbloqueado y confías en el PC
- Prueba con otro cable USB
- Si pide verificación 2FA, genera una contraseña de aplicación en appleid.apple.com

### La app no conecta con las glasses
- Verifica que el META_APP_ID coincide con tu consola de Meta Developer
- Asegúrate de que las glasses están emparejadas via Bluetooth
- Reinicia la app Meta AI en tu iPhone

### Gemini Live no conecta
- Verifica que tu API key es válida
- Asegúrate de tener conexión a internet estable
- Confirma que tienes acceso a la Gemini API en tu región

---

## Notas Importantes

- **Seguridad**: Nunca compartas tu API key públicamente. Configúrala solo dentro de la app.
- **Renovación**: Con Apple ID gratuito, reinstala cada 7 días con Sideloadly.
- **Actualizaciones**: Para actualizar OpenVision, sincroniza tu fork y re-ejecuta el workflow.
