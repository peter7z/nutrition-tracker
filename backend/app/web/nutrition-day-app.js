import { App, applyDocumentTheme } from '@modelcontextprotocol/ext-apps';

const app = new App({ name: 'Bocado Log', version: '1.0.0' });

function applyTheme(context) {
  if (context?.theme === 'light' || context?.theme === 'dark') {
    applyDocumentTheme(context.theme);
  }
}

app.ontoolresult = (result) => window.renderBocadoLogSummary?.(result);
app.addEventListener('hostcontextchanged', (event) => applyTheme(event.detail));
await app.connect();
applyTheme(app.getHostContext());
