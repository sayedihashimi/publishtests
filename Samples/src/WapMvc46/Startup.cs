using Microsoft.Owin;
using Owin;

[assembly: OwinStartupAttribute(typeof(WapMvc46.Startup))]
namespace WapMvc46
{
    public partial class Startup
    {
        public void Configuration(IAppBuilder app)
        {
            ConfigureAuth(app);
        }
    }
}
