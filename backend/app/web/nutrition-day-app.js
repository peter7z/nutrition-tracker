import { App, applyDocumentTheme } from '@modelcontextprotocol/ext-apps';

const app = new App({ name: 'Bocado Log', version: '1.0.0' });

function applyTheme(context) {
  if (context?.theme === 'light' || context?.theme === 'dark') {
    applyDocumentTheme(context.theme);
  }
}

app.ontoolresult = (result) => window.renderBocadoLogSummary?.(result);
app.onhostcontextchanged = (context) => applyTheme(context);
await app.connect();
window.bocadoCallTool = (name, args) => app.callServerTool({ name, arguments: args });
window.dispatchEvent(new Event('bocado:ready'));
applyTheme(app.getHostContext());
